import AVFoundation
import Combine
import CoreMedia
import Foundation
import os
import Testing
@testable import Hireva

#if DEBUG
/// Mixed seam: exact tasks and a finite pause before original worker bodies.
/// The actual App verification submission and App shutdown methods still run.
/// Each case constructs its own coordinator; it never starts .shared.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct VerificationCoordinatorShutdownTests {
    @Test(arguments: ["fullText", "metadata", "off", "saveOff", "revokedTicket", "changedScenario", "notStarted", "closed"])
    func localAnswerVerificationRecordsActualAttemptsOnlyWithCurrentAdmission(mode: String) async throws {
        let entry = try await LocalQwenOwnedEntryFixture()
        let app = entry.app
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalAnswerVerification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = try verificationWorkerConfiguration(root: root)
        let owner = HirevaVerificationCoordinator()
        let workers = VerificationWorkerFixture()
        app.verificationCoordinatorOverrideForTesting = owner
        owner.workerWillBeginForTesting = { await workers.pause($0) }
        owner.workerTaskDidRegisterForTesting = { workers.register($0, $1) }
        var pending: Task<Bool, Error>?
        @MainActor func cleanup() async throws {
            workers.cancelAndReleaseAll()
            await workers.joinAll()
            workers.finishEvents()
            try await entry.close(pending.map { [$0] } ?? [])
            owner.finishTestOwnedIOAfterJoiningWorkers()
            app.verificationCoordinatorOverrideForTesting = nil
            try FileManager.default.removeItem(at: root)
        }
        do {
            var settings = app.settings
            settings.saveTranscriptsLocally = mode != "saveOff"
            settings.diagnosticTraceMode = mode == "metadata" ? .metadataOnly : mode == "off" ? .off : .fullText
            app.saveSettings(settings)
            app.activateGeneration(question: entry.question, generationID: entry.generationID,
                triggerPath: .manualGenerate, requestStart: Date(), source: .mock, speaker: .unknown,
                answerProviderMode: .localQwenPrimary)
            let original = try #require(app.generationCoordinator.activeGeneration)
            if mode != "notStarted" { owner.start(appState: app, configuration: configuration) }
            if mode == "changedScenario" {
                try #"{"synthetic":false,"runID":"owned-worker-test"}"#
                    .write(to: configuration.scenarioURL, atomically: true, encoding: .utf8)
            }
            if mode == "closed" {
                workers.cancelAndReleaseAll()
                await workers.joinAll()
                #expect(await owner.shutdown())
            }
            let task = Task { try await entry.finishLocal() }
            pending = task
            for ordinal in 1...4 {
                #expect(try await entry.provider.nextStart() == ordinal)
                let launch = try #require(app.generationCoordinator.activeGeneration?.stageALaunchID)
                if ordinal == 1 {
                    owner.recordLocalAnswerEvent(.streamCompleted("FORBIDDEN_OLD_LAUNCH", launchID: UUID(), requestIndex: 0, attempt: 1),
                        identity: original.identity, persistenceTicket: original.persistenceTicket)
                    let stale = GenerationIdentity(acceptedQuestionID: original.identity.acceptedQuestionID,
                        generationID: original.generationID, sessionID: entry.session.id,
                        questionText: entry.question.questionText, promptPrimaryQuestion: entry.question.questionText,
                        contextSnapshotID: "old-context")
                    owner.recordLocalAnswerEvent(.streamCompleted("FORBIDDEN_OLD_IDENTITY", launchID: launch, requestIndex: 0, attempt: 1),
                        identity: stale, persistenceTicket: original.persistenceTicket)
                    if mode == "revokedTicket" {
                        app.persistenceConsent.update(enabled: false)
                        app.persistenceConsent.update(enabled: true)
                    }
                }
                await entry.provider.gate.release(ordinal)
                #expect(try await entry.provider.nextStream() == ordinal)
                if ordinal == 4 { entry.provider.emit(LocalQwenStreamEntryOwnershipTests.answer, ordinal: ordinal) }
                entry.provider.finish(ordinal: ordinal)
            }
            #expect(try await task.value, "Diagnostic rejection must not cancel valid generation.")
            await app.generationCoordinator.drainRetiredTasks()
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
            let eventURL = configuration.outputDirectory.appendingPathComponent("app_verification_events.jsonl")
            let text = mode == "notStarted" ? "" : try String(contentsOf: eventURL, encoding: .utf8)
            #expect(!text.contains("FORBIDDEN_OLD_"))
            let events = try text.split(separator: "\n").map {
                try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
            let requests = events.filter { $0["event"] as? String == "local_answer.request_prepared" }
            let responses = events.filter { $0["event"] as? String == "local_answer.formal_stream_completed" }
            #expect(requests.count == (mode == "fullText" ? 4 : mode == "revokedTicket" ? 1 : 0))
            #expect(responses.count == (mode == "fullText" ? 4 : 0))
            if mode == "fullText" {
                let calls = await entry.provider.gate.calls()
                try #require(requests.count == calls.count && responses.count == calls.count)
                #expect(requests.compactMap { $0["requestIndex"] as? Int } == [0, 0, 1, 2])
                #expect(requests.compactMap { $0["attempt"] as? Int } == [1, 2, 1, 1])
                #expect(Set(requests.compactMap { $0["launchID"] as? String }).count == 1)
                for index in calls.indices {
                    #expect(requests[index]["prompt"] as? String == calls[index].prompt)
                    #expect(requests[index]["systemPrompt"] as? String == calls[index].systemPrompt)
                    #expect(requests[index]["modelName"] as? String == calls[index].modelName)
                    #expect(requests[index]["temperature"] as? Double == calls[index].temperature)
                    #expect(requests[index]["numPredict"] as? Int == calls[index].numPredict)
                    #expect(requests[index]["launchID"] as? String == responses[index]["launchID"] as? String)
                    #expect(requests[index]["attempt"] as? Int == responses[index]["attempt"] as? Int)
                    #expect(requests[index]["requestIndex"] as? Int == responses[index]["requestIndex"] as? Int)
                    #expect(responses[index]["formalResponse"] as? String == (index == 3 ? LocalQwenStreamEntryOwnershipTests.answer : ""))
                }
            }
            try await cleanup()
        } catch {
            try? await cleanup()
            throw error
        }
    }

    @Test(arguments: ["synthetic", "runID"])
    func manualVerificationRechecksScenarioIdentityBeforeApplyingSettings(changedField: String) async throws {
        let environment = try await verificationWorkerEnvironment(prefix: "VerificationChangedScenario")
        let app = environment.appState
        let owner = HirevaVerificationCoordinator()
        let workers = VerificationWorkerFixture()
        app.verificationCoordinatorOverrideForTesting = owner
        owner.workerWillBeginForTesting = { phase in
            if phase == "monitor" { await workers.pause(phase) }
        }
        owner.workerTaskDidRegisterForTesting = { workers.register($0, $1) }
        owner.workerTaskDidCompleteForTesting = { workers.complete($0) }
        let configuration = try verificationWorkerConfiguration(root: environment.rootDirectory)
        var scenario = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: configuration.scenarioURL)) as? [String: Any])
        var settings = app.settings
        settings.diagnosticTraceMode = .metadataOnly
        app.saveSettings(settings)
        scenario[changedField] = changedField == "synthetic" ? false : "different-run"
        try JSONSerialization.data(withJSONObject: scenario).write(to: configuration.scenarioURL)
        let previousMode = app.settings.audioCaptureMode
        do {
            owner.start(appState: app, configuration: configuration)
            try await workers.waitForBootstrapFinalDefer()
            workers.cancelAndReleaseAll()
            await workers.joinAll()
            #expect(await owner.shutdown())
            let events = try String(contentsOf: configuration.outputDirectory.appendingPathComponent("app_verification_events.jsonl"))
            #expect(events.contains("bootstrap.failed"))
            #expect(!events.contains("bootstrap.manual_ui_ready"))
            #expect(app.settings.audioCaptureMode == previousMode)
        } catch {
            workers.cancelAndReleaseAll()
            await workers.joinAll()
            workers.finishEvents()
            owner.finishTestOwnedIOAfterJoiningWorkers()
            app.verificationCoordinatorOverrideForTesting = nil
            try? await environment.shutdown()
            throw error
        }
        workers.cancelAndReleaseAll()
        await workers.joinAll()
        workers.finishEvents()
        #expect(await app.shutdownResources())
        owner.finishTestOwnedIOAfterJoiningWorkers()
        app.verificationCoordinatorOverrideForTesting = nil
        try await environment.shutdown()
    }

    @Test(arguments: AudioCaptureMode.allCases, [false, true])
    func manualVerificationSeedsSystemOnlyAndRejectsUnsafeSessionControls(mode: AudioCaptureMode,
        changesDuringStop: Bool) async throws {
        let environment = try await verificationWorkerEnvironment(prefix: "VerificationCaptureModeBoundary")
        let app = environment.appState
        let owner = HirevaVerificationCoordinator()
        let workers = VerificationWorkerFixture()
        app.verificationCoordinatorOverrideForTesting = owner
        owner.workerWillBeginForTesting = { phase in
            if phase == "monitor" { await workers.pause(phase) }
        }
        owner.workerTaskDidRegisterForTesting = { workers.register($0, $1) }
        owner.workerTaskDidCompleteForTesting = { workers.complete($0) }
        let configuration = try verificationWorkerConfiguration(root: environment.rootDirectory)
        var settings = app.settings
        settings.audioCaptureMode = mode
        app.saveSettings(settings)
        app.setSelectedASRProvider(.localParakeet)
        var admissions = 0
        app.liveASRWillStart = { _, _ in
            admissions += 1
            throw TranscriptionError.unavailable("Synthetic backend admission ends before native capture.")
        }
        var changedDuringStop = false
        let observer = app.objectWillChange.sink { _ in
            guard changesDuringStop, mode == .systemAudioOnly, !changedDuringStop,
                  app.currentCaptureRuntimeState == .stopping else { return }
            changedDuringStop = true
            var changed = app.settings
            changed.audioCaptureMode = .microphoneAndSystem
            app.saveSettings(changed)
        }
        @MainActor func cleanup() async throws {
            observer.cancel()
            workers.cancelAndReleaseAll()
            await workers.joinAll()
            workers.finishEvents()
            #expect(await app.shutdownResources())
            owner.finishTestOwnedIOAfterJoiningWorkers()
            app.verificationCoordinatorOverrideForTesting = nil
            try await environment.shutdown()
        }
        try await withTaskCancellationHandler {
            do {
                owner.start(appState: app, configuration: configuration)
                try await workers.waitForBootstrapFinalDefer()
                #expect(app.settings.audioCaptureMode == .systemAudioOnly)
                // A later UI settings change must also be checked by the real control.
                settings.audioCaptureMode = mode
                app.saveSettings(settings)
                let session = try environment.makeContextBoundSession(mode: .microphone)
                let control = try #require(owner.submitControlForTesting("next_session"))
                await control.value
                if mode == .systemAudioOnly && !changesDuringStop {
                    #expect(admissions == 1)
                    #expect(app.currentSession?.id != session.id)
                } else {
                    #expect(admissions == 0)
                    if mode == .systemAudioOnly {
                        #expect(changedDuringStop, "Exercise the post-stop configuration recheck.")
                    } else {
                        #expect(app.currentSession?.id == session.id,
                            "An unauthorized capture mode must be rejected before stopping or clearing the existing session.")
                    }
                    #expect(app.captureStartupTask == nil)
                }
            } catch {
                try await cleanup()
                throw error
            }
            try await cleanup()
        } onCancel: { workers.cancelAndReleaseAll() }
    }

    @Test
    func applicationShutdownCancelsAndJoinsItsVerificationWorkers() async throws {
        let environment = try await verificationWorkerEnvironment(prefix: "VerificationWorkerShutdown")
        let app = environment.appState
        let coordinator = HirevaVerificationCoordinator()
        let fixture = VerificationWorkerFixture()
        app.verificationCoordinatorOverrideForTesting = coordinator
        coordinator.workerWillBeginForTesting = { await fixture.pause($0) }
        coordinator.workerTaskDidRegisterForTesting = { fixture.register($0, $1) }
        coordinator.workerTaskDidCompleteForTesting = { fixture.complete($0) }
        let configuration = try verificationWorkerConfiguration(root: environment.rootDirectory)
        var releaseOnCancellation: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                app.runVerificationBootstrapIfRequested(configuration: configuration)
                _ = coordinator.submitControlForTesting("status")
                try await fixture.waitForEnteredWorkers(3)
                #expect(fixture.taskCount == 3)
                // This finite test-owned watcher releases the gates only after
                // the production cleanup cancels one of its exact worker tasks.
                // Baseline cleanup returns without cancellation, allowing the
                // assertions to fail before ordinary fixture release/join.
                releaseOnCancellation = Task { await fixture.releaseWhenWorkerCancellationIsObserved() }
                #expect(await app.shutdownResources())
                #expect(fixture.cancelledTaskCount == 3,
                    "App reported cleanup while its submitted verification tasks were still admitted.")
                #expect(fixture.completedTaskCount == 3,
                    "Cancellation is not exit: three real Task final defers must run before App returns.")
                fixture.cancelAndReleaseAll()
                await fixture.joinAll()
                fixture.finishEvents()
                await releaseOnCancellation?.value
            } catch {
                fixture.cancelAndReleaseAll()
                await fixture.joinAll()
                fixture.finishEvents()
                await releaseOnCancellation?.value
                coordinator.finishTestOwnedIOAfterJoiningWorkers()
                app.verificationCoordinatorOverrideForTesting = nil
                try await environment.shutdown()
                throw error
            }
            coordinator.finishTestOwnedIOAfterJoiningWorkers()
            app.verificationCoordinatorOverrideForTesting = nil
            try await environment.shutdown()
        } onCancel: { fixture.cancelAndReleaseAll() }
    }

    @Test
    func closedApplicationRejectsVerificationSubmissionBeforeAnyWorkerOrObserverIsCreated() async throws {
        let environment = try await verificationWorkerEnvironment(prefix: "VerificationClosedSubmission")
        let app = environment.appState
        let coordinator = HirevaVerificationCoordinator()
        let fixture = VerificationWorkerFixture()
        app.verificationCoordinatorOverrideForTesting = coordinator
        coordinator.workerWillBeginForTesting = { await fixture.pause($0) }
        coordinator.workerTaskDidRegisterForTesting = { fixture.register($0, $1) }
        coordinator.workerTaskDidCompleteForTesting = { fixture.complete($0) }
        let configuration = try verificationWorkerConfiguration(root: environment.rootDirectory)
        try await withTaskCancellationHandler {
            #expect(await app.shutdownResources())
            app.runVerificationBootstrapIfRequested(configuration: configuration)
            #expect(fixture.taskCount == 0)
            #expect(coordinator.observerForTesting == nil,
                "A closed App registered a new distributed control observer.")
            fixture.cancelAndReleaseAll()
            await fixture.joinAll()
            fixture.finishEvents()
            coordinator.finishTestOwnedIOAfterJoiningWorkers()
            app.verificationCoordinatorOverrideForTesting = nil
            try await environment.shutdown()
        } onCancel: { fixture.cancelAndReleaseAll() }
    }

    // Stage this against the actual owner migration before the App top guard.
    // The child is never awaited by bootstrap. Its App call enters while that
    // real root is held in a cleanup join; releasing the root always breaks the
    // invalid borrow cycle and makes a missing guard fail with Bool(true).
    @Test
    func inheritedVerificationChildCannotBorrowAppCleanupAlreadyJoiningItsRoot() async throws {
        let environment = try await verificationWorkerEnvironment(prefix: "VerificationInheritedBorrow")
        let app = environment.appState
        let owner = HirevaVerificationCoordinator()
        let workers = VerificationWorkerFixture()
        let child = VerificationInheritedChildFixture()
        app.verificationCoordinatorOverrideForTesting = owner
        owner.workerTaskDidRegisterForTesting = { workers.register($0, $1) }
        owner.workerTaskDidCompleteForTesting = { workers.complete($0) }
        app.verificationShutdownScopeDidObserveForTesting = { mayDrain in
            if !mayDrain { child.markAppCallEntry() }
        }
        owner.workerWillBeginForTesting = { phase in
            await workers.pause(phase)
            if phase == "bootstrap" {
                let inherited = Task { @MainActor in
                    await app.shutdownResources()
                }
                child.register(inherited)
                await child.rootExitGate.wait()
            }
        }
        // Observation at the real owner join; no cleanup decision is replaced.
        owner.workerTaskWillJoinForTesting = { phase in
            if phase == "bootstrap" { workers.releaseAll() }
        }
        let configuration = try verificationWorkerConfiguration(root: environment.rootDirectory)
        var externalQuit: Task<Bool, Never>?
        try await withTaskCancellationHandler {
            do {
                app.runVerificationBootstrapIfRequested(configuration: configuration)
                try await workers.waitForEnteredWorkers(2)
                externalQuit = Task { @MainActor in await app.shutdownResources() }
                try await child.waitForAppCallEntry()
                child.rootExitGate.release()
                let inherited = try #require(child.observedTask)
                #expect(!(await inherited.value),
                    "An inherited child borrowed App cleanup that was joining its live root.")
                #expect(await externalQuit?.value == true)
                #expect(workers.completedTaskCount == 2)
                #expect(owner.pendingWorkerCount == 0)
            } catch {
                workers.cancelAndReleaseAll(); child.cancelAndReleaseAll()
                await workers.joinAll(); await child.join()
                _ = await externalQuit?.value
                workers.finishEvents(); child.finishEvents()
                owner.finishTestOwnedIOAfterJoiningWorkers()
                app.verificationCoordinatorOverrideForTesting = nil
                try await environment.shutdown()
                throw error
            }
            workers.cancelAndReleaseAll(); child.cancelAndReleaseAll()
            await workers.joinAll(); await child.join()
            _ = await externalQuit?.value
            workers.finishEvents(); child.finishEvents()
            owner.finishTestOwnedIOAfterJoiningWorkers()
            app.verificationCoordinatorOverrideForTesting = nil
            try await environment.shutdown()
        } onCancel: { workers.cancelAndReleaseAll(); child.cancelAndReleaseAll() }
    }

    @Test
    func completedVerificationRootMetadataDoesNotRejectItsLaterInheritedChild() async throws {
        let environment = try await verificationWorkerEnvironment(prefix: "VerificationCompletedRoot")
        let app = environment.appState
        let owner = HirevaVerificationCoordinator()
        let workers = VerificationWorkerFixture()
        let child = VerificationInheritedChildFixture()
        app.verificationCoordinatorOverrideForTesting = owner
        owner.workerTaskDidRegisterForTesting = { workers.register($0, $1) }
        owner.workerTaskDidCompleteForTesting = { workers.complete($0) }
        app.verificationShutdownScopeDidObserveForTesting = { mayDrain in
            if mayDrain { child.markAppCallEntry() }
        }
        owner.workerWillBeginForTesting = { phase in
            if phase == "monitor" { await workers.pause(phase) }
            if phase == "bootstrap" {
                let inherited = Task { @MainActor in
                    await child.appEntryGate.wait()
                    return await app.shutdownResources()
                }
                child.register(inherited)
            }
        }
        let configuration = try verificationWorkerConfiguration(root: environment.rootDirectory)
        var releaseOnCancellation: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                app.runVerificationBootstrapIfRequested(configuration: configuration)
                try await workers.waitForBootstrapFinalDefer()
                #expect(owner.pendingWorkerCount == 1,
                    "The monitor is still held while the actual bootstrap root has exited.")
                // Child keeps the old root's copied metadata. Exact worker ID
                // retirement must allow it even though the monitor is alive.
                // Keep the real monitor body paused until actual App closure
                // cancels it. No shared capture snapshot is read by this case.
                releaseOnCancellation = Task { await workers.releaseWhenWorkerCancellationIsObserved() }
                child.appEntryGate.release()
                try await child.waitForAppCallEntry()
                let inherited = try #require(child.observedTask)
                #expect(await inherited.value)
                #expect(owner.pendingWorkerCount == 0)
                #expect(!owner.hasUnreleasedResources)
            } catch {
                workers.cancelAndReleaseAll(); child.cancelAndReleaseAll()
                await workers.joinAll(); await child.join()
                workers.finishEvents(); child.finishEvents()
                await releaseOnCancellation?.value
                owner.finishTestOwnedIOAfterJoiningWorkers()
                app.verificationCoordinatorOverrideForTesting = nil
                try await environment.shutdown()
                throw error
            }
            workers.cancelAndReleaseAll(); child.cancelAndReleaseAll()
            await workers.joinAll(); await child.join()
            workers.finishEvents(); child.finishEvents()
            await releaseOnCancellation?.value
            owner.finishTestOwnedIOAfterJoiningWorkers()
            app.verificationCoordinatorOverrideForTesting = nil
            try await environment.shutdown()
        } onCancel: { workers.cancelAndReleaseAll(); child.cancelAndReleaseAll() }
    }

    // New per-App ownership characterization, executed after the production
    // migration. It does not claim a failure against the original private API.
    @Test
    func closingOneAppDoesNotCancelAnotherAppsVerificationWorkers() async throws {
        let first = try await verificationWorkerEnvironment(prefix: "VerificationFirstOwner")
        let second: HirevaTestEnvironment
        do { second = try await verificationWorkerEnvironment(prefix: "VerificationSecondOwner") }
        catch {
            do { try await first.shutdown() }
            catch let cleanupError { Issue.record(cleanupError) }
            throw error
        }
        let firstOwner = HirevaVerificationCoordinator()
        let secondOwner = HirevaVerificationCoordinator()
        let firstFixture = VerificationWorkerFixture()
        let secondFixture = VerificationWorkerFixture()
        first.appState.verificationCoordinatorOverrideForTesting = firstOwner
        second.appState.verificationCoordinatorOverrideForTesting = secondOwner
        firstOwner.workerWillBeginForTesting = { await firstFixture.pause($0) }
        secondOwner.workerWillBeginForTesting = { await secondFixture.pause($0) }
        firstOwner.workerTaskDidRegisterForTesting = { firstFixture.register($0, $1) }
        firstOwner.workerTaskDidCompleteForTesting = { firstFixture.complete($0) }
        secondOwner.workerTaskDidRegisterForTesting = { secondFixture.register($0, $1) }
        secondOwner.workerTaskDidCompleteForTesting = { secondFixture.complete($0) }
        let firstConfig = try verificationWorkerConfiguration(root: first.rootDirectory)
        let secondConfig = try verificationWorkerConfiguration(root: second.rootDirectory)
        var firstRelease: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                first.appState.runVerificationBootstrapIfRequested(configuration: firstConfig)
                second.appState.runVerificationBootstrapIfRequested(configuration: secondConfig)
                try await firstFixture.waitForEnteredWorkers(2)
                try await secondFixture.waitForEnteredWorkers(2)
                firstRelease = Task { await firstFixture.releaseWhenWorkerCancellationIsObserved() }
                #expect(await first.appState.shutdownResources())
                #expect(firstFixture.cancelledTaskCount == 2)
                #expect(firstFixture.completedTaskCount == 2)
                #expect(secondFixture.cancelledTaskCount == 0,
                    "An App shutdown cancelled another App's exact verification tasks.")
                #expect(secondOwner.pendingWorkerCount == 2)
            } catch {
                firstFixture.cancelAndReleaseAll(); secondFixture.cancelAndReleaseAll()
                await firstFixture.joinAll(); await secondFixture.joinAll()
                firstFixture.finishEvents(); secondFixture.finishEvents()
                await firstRelease?.value
                firstOwner.finishTestOwnedIOAfterJoiningWorkers()
                secondOwner.finishTestOwnedIOAfterJoiningWorkers()
                first.appState.verificationCoordinatorOverrideForTesting = nil
                second.appState.verificationCoordinatorOverrideForTesting = nil
                try await first.shutdown(); try await second.shutdown()
                throw error
            }
            firstFixture.cancelAndReleaseAll(); secondFixture.cancelAndReleaseAll()
            await firstFixture.joinAll(); await secondFixture.joinAll()
            firstFixture.finishEvents(); secondFixture.finishEvents()
            await firstRelease?.value
            #expect(await second.appState.shutdownResources())
            firstOwner.finishTestOwnedIOAfterJoiningWorkers()
            secondOwner.finishTestOwnedIOAfterJoiningWorkers()
            first.appState.verificationCoordinatorOverrideForTesting = nil
            second.appState.verificationCoordinatorOverrideForTesting = nil
            try await first.shutdown(); try await second.shutdown()
        } onCancel: {
            firstFixture.cancelAndReleaseAll(); secondFixture.cancelAndReleaseAll()
        }
    }

    @Test
    func queuedControlsHaveAnExplicitFiniteAdmissionBoundary() async throws {
        let environment = try await verificationWorkerEnvironment(prefix: "VerificationBoundedControl")
        let owner = HirevaVerificationCoordinator()
        let fixture = VerificationWorkerFixture()
        environment.appState.verificationCoordinatorOverrideForTesting = owner
        owner.workerWillBeginForTesting = { await fixture.pause($0) }
        owner.workerTaskDidRegisterForTesting = { fixture.register($0, $1) }
        owner.workerTaskDidCompleteForTesting = { fixture.complete($0) }
        let configuration = try verificationWorkerConfiguration(root: environment.rootDirectory)
        try await withTaskCancellationHandler {
            do {
                environment.appState.runVerificationBootstrapIfRequested(configuration: configuration)
                for _ in 0..<8 { #expect(owner.submitControlForTesting("status") != nil) }
                #expect(owner.submitControlForTesting("status") == nil)
                #expect(fixture.taskCount == 10)
                #expect(owner.pendingWorkerCount == 10)
                try await fixture.waitForEnteredWorkers(10)
                fixture.cancelAndReleaseAll()
                await fixture.joinAll()
                fixture.finishEvents()
                #expect(await environment.appState.shutdownResources())
                #expect(owner.pendingWorkerCount == 0)
                #expect(fixture.completedTaskCount == 10)
            } catch {
                fixture.cancelAndReleaseAll()
                await fixture.joinAll()
                fixture.finishEvents()
                owner.finishTestOwnedIOAfterJoiningWorkers()
                environment.appState.verificationCoordinatorOverrideForTesting = nil
                try await environment.shutdown()
                throw error
            }
            owner.finishTestOwnedIOAfterJoiningWorkers()
            environment.appState.verificationCoordinatorOverrideForTesting = nil
            try await environment.shutdown()
        } onCancel: { fixture.cancelAndReleaseAll() }
    }

    @Test
    func workCountControlProjectsRetainedLiveRootWithoutTextOrRepositoryFields() async throws {
        let environment = try await verificationWorkerEnvironment(prefix: "VerificationWorkCounts")
        let configuration: HirevaVerificationConfiguration
        do { configuration = try verificationWorkerConfiguration(root: environment.rootDirectory) }
        catch { try? await environment.shutdown(); throw error }
        let app = environment.appState
        let coordinator = HirevaVerificationCoordinator()
        let workers = VerificationWorkerFixture()
        app.verificationCoordinatorOverrideForTesting = coordinator
        coordinator.workerWillBeginForTesting = { phase in
            if phase != "control" { await workers.pause(phase) }
        }
        coordinator.workerTaskDidRegisterForTesting = { workers.register($0, $1) }
        var settings = app.settings
        settings.diagnosticTraceMode = .metadataOnly
        app.saveSettings(settings)
        let eventURL = configuration.outputDirectory.appendingPathComponent("app_verification_events.jsonl")
        @MainActor func metricEvents() throws -> [[String: Any]] {
            try String(contentsOf: eventURL, encoding: .utf8).split(separator: "\n").map {
                try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }.filter { $0["event"] as? String == "work_counts" }
        }
        @MainActor func cleanup() async throws {
            workers.cancelAndReleaseAll()
            await workers.joinAll()
            workers.finishEvents()
            #expect(await app.liveInterview.drainAutomaticDetection())
            #expect(await app.shutdownResources())
            coordinator.finishTestOwnedIOAfterJoiningWorkers()
            app.verificationCoordinatorOverrideForTesting = nil
            try await environment.shutdown()
        }
        try await withTaskCancellationHandler {
            do {
                coordinator.start(appState: app, configuration: configuration)
                try await workers.waitForEnteredWorkers(2)
                let root = try #require(app.liveInterview.submitAutomaticDetection { _ in
                    await workers.pause("held_live_root")
                })
                workers.register("held_live_root", root)
                try await workers.waitForEnteredWorkers(1)
                let first = try #require(coordinator.submitControlForTesting("work_counts"))
                await first.value
                let before = try #require(try metricEvents().last)
                #expect(before["verificationPendingTasks"] as? Int == 3,
                    "The executing metric control is itself counted beside the held monitor/bootstrap roots.")
                #expect(before["liveDetectionActiveTasks"] as? Int == 1)
                #expect(before["liveDetectionRetiringTasks"] as? Int == 0)
                app.liveInterview.cancelAutomaticDetection()
                #expect(root.isCancelled)
                let second = try #require(coordinator.submitControlForTesting("work_counts"))
                await second.value
                let receipts = try metricEvents()
                #expect(receipts.count == 2)
                let after = try #require(receipts.last)
                #expect(after["liveDetectionActiveTasks"] as? Int == 0)
                #expect(after["liveDetectionRetiringTasks"] as? Int == 1,
                    "Cancelled original root remains retained while its exact gate is held.")
                #expect(after["liveDetectionPendingTasks"] as? Int == 1)
                #expect(after["localParakeetOwnerVisible"] as? Int == 0)
                #expect(after["parakeetOwnedWorkPresent"] == nil,
                    "Absent current provider means this indicator is unavailable, not proof of global ASR release.")
                #expect(after["parakeetCleanupFailurePresent"] == nil)
                let metadataKeys: Set<String> = ["event", "timestamp"]
                for receipt in receipts {
                    let numericFields = receipt.filter { !metadataKeys.contains($0.key) }
                    #expect(numericFields.values.allSatisfy { $0 is NSNumber })
                    #expect(receipt["text"] == nil && receipt["answer"] == nil && receipt["databasePath"] == nil)
                    #expect(receipt["suggestionRows"] == nil && receipt["sessionID"] == nil)
                    #expect((receipt["workMetricsMonotonicNS"] as? NSNumber)?.uint64Value ?? 0 > 0)
                }
            } catch {
                try await cleanup()
                throw error
            }
            try await cleanup()
        } onCancel: {
            workers.cancelAndReleaseAll()
            workers.finishEvents()
        }
    }

    @Test
    func firstBufferEventRejectsPreviousCaptureMetricsBeforeFreshDelivery() async throws {
        let trace = TestEventWaitTrace(label: "verification.first-buffer")
        trace.mark("test.entered")
        trace.mark("body.entered")
        let oldStream = VerificationFirstBufferStream()
        let newStream = VerificationFirstBufferStream()
        let foreignStream = VerificationFirstBufferStream()
        let streams = [oldStream, newStream, foreignStream]
        var creations = 0
        let capture = ScreenCaptureKitSystemAudioCaptureService(streamFactory: {
            guard streams.indices.contains(creations) else {
                throw NSError(domain: "VerificationFirstBuffer", code: 1)
            }
            defer { creations += 1 }
            return streams[creations]
        })
        trace.mark("fixture.environment.create_requested")
        let environment = try await HirevaTestEnvironment(prefix: "VerificationFirstBuffer", systemAudioCaptureService: capture)
        trace.mark("fixture.environment.created")
        let configuration: HirevaVerificationConfiguration
        trace.mark("fixture.configuration.create_requested")
        do { configuration = try verificationWorkerConfiguration(root: environment.rootDirectory) }
        catch { try? await environment.shutdown(); throw error }
        trace.mark("fixture.configuration.created")
        let app = environment.appState
        let provider = LocalParakeetASRProvider(modelManager: VerificationFirstBufferInstalledModel(),
            runtimeClient: VerificationFirstBufferRuntime(), systemAudioCaptureService: capture)
        let foreignProvider = LocalParakeetASRProvider(modelManager: VerificationFirstBufferInstalledModel(),
            runtimeClient: VerificationFirstBufferRuntime(), systemAudioCaptureService: capture)
        app.activeASRProviderRuntime = provider
        var retainedStreams: [AsyncThrowingStream<TranscriptSegment, Error>] = []
        let coordinator = HirevaVerificationCoordinator()
        let workers = VerificationWorkerFixture()
        let published = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingOldest(4))
        let subscription = capture.totalBuffersReceivedUpdates.sink { count in
            trace.mark("producer.numeric_snapshot.\(count)")
            if count > 0 { published.continuation.yield(count) }
        }
        app.verificationCoordinatorOverrideForTesting = coordinator
        coordinator.workerWillBeginForTesting = { await workers.pause($0) }
        coordinator.workerTaskDidRegisterForTesting = { workers.register($0, $1) }
        let eventURL = configuration.outputDirectory.appendingPathComponent("app_verification_events.jsonl")
        var settings = app.settings
        settings.diagnosticTraceMode = .metadataOnly
        settings.saveTranscriptsLocally = true
        app.saveSettings(settings)
        @MainActor func firstBufferEvents() throws -> [[String: Any]] {
            let text = try String(contentsOf: eventURL, encoding: .utf8)
            return try text.split(separator: "\n").map {
                try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }.filter { $0["event"] as? String == "sck.first_buffer" }
        }
        trace.mark("setup.finished")
        trace.mark("fixture.ready")
        @MainActor func cleanup() async throws {
            trace.mark("cleanup.entered")
            workers.cancelAndReleaseAll()
            trace.mark("cleanup.workers_join_requested")
            await workers.joinAll()
            trace.mark("cleanup.workers_joined")
            #expect(coordinator.pendingWorkerCount == 0)
            workers.finishEvents()
            subscription.cancel()
            published.continuation.finish()
            // Each concrete provider joins its own exact capture/runtime.
            // A stale receipt cannot stop the foreign replacement.
            trace.mark("cleanup.provider_stop_requested")
            await provider.stopTranscription()
            trace.mark("cleanup.provider_stopped")
            trace.mark("cleanup.foreign_provider_stop_requested")
            await foreignProvider.stopTranscription()
            trace.mark("cleanup.foreign_provider_stopped")
            #expect(!provider.hasOwnedTranscriptionWork)
            #expect(!foreignProvider.hasOwnedTranscriptionWork)
            retainedStreams.removeAll()
            trace.mark("cleanup.capture_stop_requested")
            capture.stopSystemAudioCapture()
            do { try await capture.finishStoppingSystemAudioCapture() }
            catch { Issue.record("Owned synthetic capture cleanup failed: \(error)") }
            trace.mark("cleanup.capture_stopped")
            trace.mark("cleanup.app_shutdown_requested")
            #expect(await app.shutdownResources())
            trace.mark("cleanup.app_shutdown")
            coordinator.finishTestOwnedIOAfterJoiningWorkers()
            app.verificationCoordinatorOverrideForTesting = nil
            trace.mark("cleanup.environment_shutdown_requested")
            try await environment.shutdown()
            trace.mark("cleanup.finished")
        }
        try await withTaskCancellationHandler {
            trace.mark("operation.entered")
            do {
                let oldSession = try environment.makeContextBoundSession()
                app.lastCaptureStartedAt = Date(timeIntervalSince1970: 100)
                coordinator.start(appState: app, configuration: configuration)
                // start synchronously registers both exact workers and opens
                // the writer. This poll tests capture receipt admission, not
                // worker readiness; their pause gate and final join remain.
                #expect(workers.taskCount == 2)
                trace.mark("workers.registered")
                trace.mark("capture.oldSession.start_requested")
                retainedStreams.append(try await provider.startTranscription(
                    config: .init(sessionID: oldSession.id, captureMode: .systemAudioOnly)))
                trace.mark("capture.oldSession.started")
                #expect(app.ownsCurrentSystemAudioCaptureRuntime)
                let sample = try verificationFirstBufferSample()
                capture.receiveAudioSampleBuffer(sample, from: oldStream)
                _ = try await trace.nextEvent(in: published.stream, event: "old_numeric_snapshot_committed")
                trace.mark("capture.oldSession.first_buffer_observed")
                // Only wall-clock dates are synthetic. Ownership, conversion,
                // count, committed snapshot and event admission are real paths.
                capture.lastBufferReceivedAt = Date(timeIntervalSince1970: 200)
                coordinator.captureObservableEventsForTesting()
                #expect(try firstBufferEvents().map { $0["sessionID"] as? String } == [oldSession.id])
                trace.mark("capture.old_stop_requested")
                await provider.stopTranscription()
                trace.mark("capture.old_stopped")
                let currentSession = try environment.makeContextBoundSession()
                // The wall clock moved backward. A timestamp-only >= start
                // guard would wrongly accept the retained old time of 200.
                app.lastCaptureStartedAt = Date(timeIntervalSince1970: 100)
                trace.mark("capture.currentSession.start_requested")
                retainedStreams.append(try await provider.startTranscription(
                    config: .init(sessionID: currentSession.id, captureMode: .systemAudioOnly)))
                trace.mark("capture.currentSession.started")
                #expect(app.ownsCurrentSystemAudioCaptureRuntime)
                #expect(capture.totalBuffersReceived == 1, "Lifetime counter is retained; it is not fresh-delivery proof.")
                coordinator.captureObservableEventsForTesting()
                #expect(try firstBufferEvents().count == 1, "Old revision must be rejected even when old time is later than the new start.")
                capture.receiveAudioSampleBuffer(sample, from: oldStream)
                coordinator.captureObservableEventsForTesting()
                #expect(try firstBufferEvents().count == 1, "Rejected old-stream callback does not prove current delivery.")
                capture.receiveAudioSampleBuffer(sample, from: newStream)
                _ = try await trace.nextEvent(in: published.stream, event: "current_numeric_snapshot_committed")
                trace.mark("capture.currentSession.fresh_buffer_observed")
                // A fresh admitted callback remains valid after further clock
                // rollback; temporal ordering is not capture-epoch identity.
                capture.lastBufferReceivedAt = Date(timeIntervalSince1970: 50)
                coordinator.captureObservableEventsForTesting()
                coordinator.captureObservableEventsForTesting()
                #expect(try firstBufferEvents().map { $0["sessionID"] as? String } == [oldSession.id, currentSession.id])
                let committedEvents = try firstBufferEvents()
                let currentEvent = try #require(committedEvents.first { $0["sessionID"] as? String == currentSession.id })
                #expect(currentEvent["lastBufferAt"] as? String ==
                    ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 50)))
                let foreignSession = try environment.makeContextBoundSession()
                app.lastCaptureStartedAt = Date(timeIntervalSince1970: 0)
                trace.mark("capture.foreignSession.start_requested")
                retainedStreams.append(try await foreignProvider.startTranscription(
                    config: .init(sessionID: foreignSession.id, captureMode: .systemAudioOnly)))
                trace.mark("capture.foreignSession.started")
                #expect(!app.ownsCurrentSystemAudioCaptureRuntime,
                    "The App still holds the prior provider, not this same-service replacement receipt.")
                capture.receiveAudioSampleBuffer(sample, from: foreignStream)
                _ = try await trace.nextEvent(in: published.stream, event: "foreign_numeric_snapshot_committed")
                trace.mark("capture.foreignSession.fresh_buffer_observed")
                coordinator.captureObservableEventsForTesting()
                #expect(try firstBufferEvents().count == 2,
                    "A fresh service callback cannot be attributed to an App with a foreign capture receipt.")
                app.activeASRProviderRuntime = foreignProvider
                #expect(app.ownsCurrentSystemAudioCaptureRuntime)
                coordinator.captureObservableEventsForTesting()
                coordinator.captureObservableEventsForTesting()
                #expect(try firstBufferEvents().map { $0["sessionID"] as? String } ==
                    [oldSession.id, currentSession.id, foreignSession.id])
            } catch {
                trace.mark("fixture.close.error_path.requested")
                try await cleanup()
                trace.mark("fixture.close.error_path.returned")
                throw error
            }
            trace.mark("fixture.close.requested")
            try await cleanup()
            trace.mark("fixture.close.returned")
        } onCancel: {
            trace.mark("operation.cancelled")
            workers.cancelAndReleaseAll()
            published.continuation.finish()
        }
    }

}

private final class VerificationWorkerFixture: Sendable {
    private struct State: Sendable {
        var tasks: [Task<Void, Never>] = []
        var released = false
        var completedPhases: [String] = []
        var continuations: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let entered = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(12))
    private let cancelled = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(12))
    private let completed = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(12))
    private let trace = TestEventWaitTrace(label: "verification.owned-workers")
    var taskCount: Int { state.withLock { $0.tasks.count } }
    var completedTaskCount: Int { state.withLock { $0.completedPhases.count } }
    func complete(_ phase: String) {
        state.withLock { $0.completedPhases.append(phase) }
        completed.continuation.yield(phase)
    }
    var cancelledTaskCount: Int { state.withLock { $0.tasks.filter(\.isCancelled).count } }
    func register(_ phase: String, _ task: Task<Void, Never>) {
        let released = state.withLock { state in state.tasks.append(task); return state.released }
        if released { task.cancel() }
    }
    func pause(_ phase: String) async {
        entered.continuation.yield(phase)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let released = state.withLock { state in
                    guard !state.released else { return true }
                    state.continuations.append(continuation)
                    return false
                }
                if released { continuation.resume() }
            }
        } onCancel: {
            self.cancelled.continuation.yield(phase)
        }
    }
    func waitForEnteredWorkers(_ count: Int) async throws {
        for _ in 0..<count { _ = try await trace.nextEvent(in: entered.stream, event: "worker_entered") }
    }
    func waitForBootstrapFinalDefer() async throws {
        while try await trace.nextEvent(in: completed.stream, event: "worker_final_defer") != "bootstrap" {}
    }
    func releaseWhenWorkerCancellationIsObserved() async {
        var iterator = cancelled.stream.makeAsyncIterator()
        guard await iterator.next() != nil else { return }
        releaseAll()
    }
    func releaseAll() {
        let continuations = state.withLock { state in
            state.released = true
            let pending = state.continuations
            state.continuations.removeAll()
            return pending
        }
        continuations.forEach { $0.resume() }
    }
    func cancelAndReleaseAll() {
        let tasks = state.withLock { $0.tasks }
        tasks.forEach { $0.cancel() }
        releaseAll()
    }
    func joinAll() async {
        let tasks = state.withLock { $0.tasks }
        for task in tasks { await task.value }
    }
    func finishEvents() {
        entered.continuation.finish(); cancelled.continuation.finish(); completed.continuation.finish()
    }
}

// Test-owned finite gates ignore child cancellation until the owning test
// releases them. Parent cancellation always releases them synchronously.
private final class VerificationScopeGate: Sendable {
    private struct State: Sendable {
        var released = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    func wait() async {
        await withCheckedContinuation { waiter in
            let released = state.withLock { state in
                guard !state.released else { return true }
                state.waiters.append(waiter)
                return false
            }
            if released { waiter.resume() }
        }
    }
    func release() {
        let waiters = state.withLock { state in
            state.released = true
            let old = state.waiters; state.waiters.removeAll()
            return old
        }
        waiters.forEach { $0.resume() }
    }
}

private final class VerificationInheritedChildFixture: Sendable {
    private struct State: Sendable {
        var task: Task<Bool, Never>?
        var released = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let rootExitGate = VerificationScopeGate()
    let appEntryGate = VerificationScopeGate()
    private let entries = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(2))
    private let trace = TestEventWaitTrace(label: "verification.inherited-child")
    var observedTask: Task<Bool, Never>? { state.withLock { $0.task } }
    func register(_ task: Task<Bool, Never>) {
        let released = state.withLock { state in state.task = task; return state.released }
        if released { task.cancel() }
    }
    func markAppCallEntry() { entries.continuation.yield(()) }
    func waitForAppCallEntry() async throws {
        _ = try await trace.nextEvent(in: entries.stream, event: "actual_child_app_call")
    }
    func cancelAndReleaseAll() {
        let task = state.withLock { state in state.released = true; return state.task }
        task?.cancel()
        rootExitGate.release(); appEntryGate.release()
    }
    func join() async { _ = await observedTask?.value }
    func finishEvents() { entries.continuation.finish() }
}

@MainActor
private func verificationWorkerEnvironment(prefix: String) async throws -> HirevaTestEnvironment {
    let permissions = HermeticPermissionService()
    let permissionOwner = SystemAudioPermissionController(permissions: permissions,
        probe: { .init(preflightGranted: true, shareableContentProbeSucceeded: true,
            streamAudioProbeSucceeded: true, errorDescription: nil, likelyIdentityMismatch: false) },
        stopProbe: { (_: Bool) in })
    return try await HirevaTestEnvironment(prefix: prefix, permissionService: permissions,
        systemAudioPermissions: permissionOwner)
}

@MainActor
private func verificationWorkerConfiguration(root: URL) throws -> HirevaVerificationConfiguration {
    let output = root.appendingPathComponent("verification-owned-output", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let scenario = root.appendingPathComponent("verification-owned-scenario.json")
    try #"{"synthetic":true,"runID":"owned-worker-test","manualUI":true,"requiresLocalASR":true}"#
        .write(to: scenario, atomically: true, encoding: .utf8)
    return .init(runID: "owned-worker-test", scenarioURL: scenario, outputDirectory: output,
        applicationSupportDirectory: root, localModelsDirectory: nil,
        userDefaultsSuiteName: "com.langcheng.Hireva.tests.verification-workers.\(UUID().uuidString)",
        controlledAudioProcessID: nil, controlledAudioBundleIdentifier: nil)
}
@MainActor
private final class VerificationFirstBufferRuntime: ParakeetRuntimeClient {
    private var continuation: AsyncThrowingStream<ParakeetTranscriptEvent, Error>.Continuation?
    func isRuntimeAvailable() async -> Bool { true }
    func startTranscription(modelDirectory: URL, config: ASRConfig) async throws
        -> AsyncThrowingStream<ParakeetTranscriptEvent, Error> {
        let pair = AsyncThrowingStream<ParakeetTranscriptEvent, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }
    func stop() async { continuation?.finish(); continuation = nil }
    nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {}
}

private final class VerificationFirstBufferInstalledModel: LocalModelManager {
    func modelStatus(_ model: LocalModelDescriptor) async -> LocalModelStatus { .installed }
    func downloadModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func deleteModel(_ model: LocalModelDescriptor) async throws {}
    func verifyModel(_ model: LocalModelDescriptor) async throws -> Bool { true }
    func fileURL(for model: LocalModelDescriptor) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-first-buffer-model")
    }
}

private final class VerificationFirstBufferStream: SystemAudioCaptureStream {
    @MainActor func startCapture() async throws {}
    @MainActor func stopCapture() async throws {}
}

private func verificationFirstBufferSample() throws -> CMSampleBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
    pcm.frameLength = 16
    for index in 0..<16 { pcm.floatChannelData?[0][index] = 0.1 }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    #expect(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
        dataReady: false, makeDataReadyCallback: nil, refcon: nil,
        formatDescription: format.formatDescription, sampleCount: 16,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
    let created = try #require(sample)
    #expect(CMSampleBufferSetDataBufferFromAudioBufferList(created,
        blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: 0, bufferList: pcm.audioBufferList) == noErr)
    #expect(CMSampleBufferSetDataReady(created) == noErr)
    return created
}

#endif
