import AVFoundation
import Combine
import Foundation
import Testing
@testable import Hireva

// Each test has its own provider, concrete SCK owner, fake stream and gates.
// The native-I/O stand-in proves owned handle joins, not real SCK or ASR quality.
@Suite("Parakeet exact native capture stop")
@MainActor
struct ParakeetExactNativeStopTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func failedStartupRetainsItsExactCleanupOwnerBeforeAnotherLiveAdmission(stopAtPublication: Bool) async throws {
        let fixture = NativeFixture()
        let permissions = HermeticPermissionService()
        let permissionOwner = SystemAudioPermissionController(permissions: permissions,
            probe: { .init(preflightGranted: true, shareableContentProbeSucceeded: true,
                streamAudioProbeSucceeded: true, errorDescription: nil, likelyIdentityMismatch: false) },
            stopProbe: { (_: Bool) in })
        let environment = try await HirevaTestEnvironment(prefix: "ParakeetFailedStartupOwner",
            permissionService: permissions, systemAudioCaptureService: fixture.capture,
            systemAudioPermissions: permissionOwner)
        let app = environment.appState
        var settings = app.settings
        settings.audioCaptureMode = .systemAudioOnly
        settings.saveTranscriptsLocally = false
        app.saveSettings(settings)
        app.setSelectedASRProvider(.localParakeet)
        var admissions = 0
        // Existing admission observer supplies an already failed concrete owner;
        // actual App catch/queue/restart paths run without opening native devices.
        app.liveASRWillStart = { _, _ in
            admissions += 1
            app.activeASRProviderRuntime = fixture.provider
            throw ParakeetSidecarError.resourceCleanupIncomplete
        }
        var stoppedAtPublication = false
        let observer = app.objectWillChange.sink { _ in
            guard stopAtPublication, !stoppedAtPublication, admissions == 1,
                  app.activeASRProviderRuntime == nil, app.captureTeardownTask != nil,
                  app.captureStartupID != nil else { return }
            stoppedAtPublication = true
            app.stopListening(reason: .userRequested)
        }
        defer { observer.cancel() }
        do {
            _ = try await fixture.provider.startTranscription(config: config("failed-startup-owner"))
            fixture.runtime.cleanupFailure = ParakeetSidecarError.resourceCleanupIncomplete
            await fixture.provider.stopTranscription()
            #expect(!fixture.stream.running)
            app.startListening(mode: .microphone)
            await app.captureStartupTask?.value
            await app.captureTeardownTask?.value
            #expect(admissions == 1)
            if stopAtPublication {
                #expect(stoppedAtPublication)
                #expect(app.liveState == .stopped, "A revoked startup catch must not overwrite the synchronous Stop intent.")
            }
            #expect(app.captureLifecycle.hasFailedTeardown)
            #expect(app.canStopCapture && app.primaryHomeActionShouldStop)
            app.startListening(mode: .microphone)
            await app.captureStartupTask?.value
            #expect(admissions == 1, "A new Live startup must not overwrite failed native cleanup ownership.")
            fixture.runtime.cleanupFailure = nil
            app.stopListening(reason: .userRequested)
            await app.captureLifecycle.drain()
            #expect(!app.captureLifecycle.hasFailedTeardown)
            #expect(!fixture.provider.hasOwnedTranscriptionWork)
            app.liveASRWillStart = { _, _ in
                admissions += 1
                throw TranscriptionError.unavailable("Synthetic restart ends before native capture.")
            }
            app.startListening(mode: .microphone)
            await app.captureStartupTask?.value
            #expect(admissions == 2, "Successful explicit cleanup restores admission without reusing the failed provider.")
            #expect(await app.shutdownResources())
            await fixture.cleanup()
            try await environment.shutdown()
        } catch {
            fixture.runtime.cleanupFailure = nil
            await fixture.cleanup()
            try? await environment.shutdown()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func successfulCaptureStopCannotEraseTheRuntimeCleanupOwner() async throws {
        let fixture = NativeFixture()
        let environment = try await HirevaTestEnvironment(prefix: "ParakeetRuntimeCleanup")
        do {
            _ = try await fixture.provider.startTranscription(config: config("runtime-cleanup-failed"))
            fixture.runtime.cleanupFailure = ParakeetSidecarError.resourceCleanupIncomplete
            await fixture.provider.stopTranscription()
            #expect(!fixture.stream.running)
            #expect(fixture.provider.captureCleanupFailure != nil)
            #expect(fixture.provider.hasOwnedTranscriptionWork)
            environment.appState.activeASRProviderRuntime = fixture.provider
            #expect(await environment.appState.shutdownResources() == false)
            do {
                _ = try await fixture.provider.startTranscription(config: config("blocked-new-round"))
                Issue.record("Runtime cleanup failure must prevent replacement admission.")
            } catch { #expect(error as? ParakeetSidecarError == .resourceCleanupIncomplete) }
            #expect(fixture.runtime.startCalls == 1)
            fixture.runtime.cleanupFailure = nil
            #expect(await environment.appState.shutdownResources())
            #expect(!fixture.provider.hasOwnedTranscriptionWork)
            await fixture.cleanup()
            try await environment.shutdown()
        } catch {
            fixture.runtime.cleanupFailure = nil
            await fixture.cleanup()
            try? await environment.shutdown()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitProviderStopReturnsOnlyAfterItsNativeCaptureHasExited() async throws {
        let fixture = NativeFixture()
        try await fixture.run {
            _ = try await fixture.provider.startTranscription(config: config("explicit-stop"))
            #expect(fixture.stream.running)
            fixture.releaseOnJoin.armed = true

            await fixture.provider.stopTranscription()
            try await fixture.stream.stopGate.waitUntilEntered()

            #expect(!fixture.stream.running)
            #expect(!fixture.runtime.running)
            #expect(!fixture.provider.hasOwnedTranscriptionWork)
            #expect(fixture.stream.stopCalls == 1)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func normalRuntimeEOFFinishesConsumerOnlyAfterNativeCaptureHasExited() async throws {
        let fixture = NativeFixture()
        var consumer: Task<Void, Error>?
        do {
            let stream = try await fixture.provider.startTranscription(config: config("normal-eof"))
            let task = Task { for try await _ in stream {} }
            consumer = task
            fixture.releaseOnJoin.armed = true
            fixture.runtime.finish()

            try await task.value
            await fixture.provider.waitForCurrentTranscriptionEnd()
            try await fixture.stream.stopGate.waitUntilEntered()
            #expect(!fixture.stream.running)
            #expect(!fixture.runtime.running)
            #expect(!fixture.provider.hasOwnedTranscriptionWork)
            #expect(fixture.stream.stopCalls == 1)
            await fixture.cleanup()
        } catch {
            await fixture.cleanup()
            consumer?.cancel()
            _ = await consumer?.result
            throw error
        }
        consumer?.cancel()
        _ = await consumer?.result
    }

    @Test(.timeLimit(.minutes(1)))
    func joiningAnOldCapturedStopCannotStopTheReplacementNativeStream() async throws {
        let first = NativeStream()
        let second = NativeStream()
        let release = StopReleasePolicy(streams: [first, second])
        let factory = StreamFactory(streams: [first, second])
        let capture = ScreenCaptureKitSystemAudioCaptureService(
            streamFactory: { try factory.next() },
            onFinishStoppingEntered: { release.joinEntered() }
        )
        let runtime = NativeRuntime()
        let provider = LocalParakeetASRProvider(modelManager: InstalledModelManager(),
            runtimeClient: runtime, systemAudioCaptureService: capture)
        do {
            _ = try await provider.startTranscription(config: config("old-stop"))
            let capturedStop = capture.stopSystemAudioCapture()
            release.armed = true
            await provider.stopTranscription()
            // Prove the legacy provider returned before native exit, then release
            // our own latch before replacement startup can await the SCK fence.
            #expect(!first.running)
            first.stopGate.open()
            _ = try await provider.startTranscription(config: config("replacement"))
            #expect(!first.running)
            #expect(second.running)
            #expect(!factory.startedBeforePreviousExit)

            try await capture.finishStoppingSystemAudioCapture(capturedStop: capturedStop)
            #expect(second.running)
            #expect(second.stopCalls == 0)
            #expect(first.stopCalls == 1)
            await provider.stopTranscription()
            try await capture.finishStoppingSystemAudioCapture()
            #expect(!second.running)
        } catch {
            release.openAll()
            await provider.stopTranscription()
            _ = try? await capture.finishStoppingSystemAudioCapture()
            throw error
        }
        release.openAll()
        await provider.stopTranscription()
        _ = try? await capture.finishStoppingSystemAudioCapture()
    }

    @Test(.timeLimit(.minutes(1)))
    func failedNativeStopRemainsVisibleAndAppShutdownCannotClaimResourcesReleased() async throws {
        let fixture = NativeFixture()
        let environment = try await HirevaTestEnvironment(prefix: "ParakeetExactNativeStop")
        do {
            _ = try await fixture.provider.startTranscription(config: config("failed-stop"))
            fixture.stream.stopFailure = FixtureFailure.nativeStop
            fixture.releaseOnJoin.armed = true
            await fixture.provider.stopTranscription()
            try await fixture.stream.stopGate.waitUntilEntered()

            #expect(fixture.provider.captureCleanupFailure != nil)
            #expect(fixture.stream.running)
            #expect(!fixture.runtime.running)
            environment.appState.activeASRProviderRuntime = fixture.provider
            let released = await environment.appState.shutdownResources()
            #expect(!released)

            // The legacy provider may never enter the native join observer.
            // Release this test-owned latch before probing failed-fence restart.
            fixture.stream.stopGate.open()
            _ = try? await fixture.capture.finishStoppingSystemAudioCapture()
            do {
                _ = try await fixture.provider.startTranscription(config: config("unsafe-restart"))
                Issue.record("A failed native stop permitted another provider round")
            } catch {
                #expect(error as? FixtureFailure == .nativeStop)
            }
            #expect(fixture.runtime.startCalls == 1)
            await fixture.cleanup()
            try await environment.shutdown()
        } catch {
            await fixture.cleanup()
            try? await environment.shutdown()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func appStopRetainsTheOriginalFailedProviderForExplicitShutdownRetry() async throws {
        let fixture = NativeFixture()
        let database = try AppDatabase(inMemory: true)
        let suite = "com.langcheng.Hireva.tests.stopped-failed-provider." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        var settings = AppSettings.default
        settings.saveTranscriptsLocally = false
        settings.audioCaptureMode = .systemAudioOnly
        settings.automaticQuestionDetectionEnabled = false
        settings.manualOnlyMode = true
        try SettingsRepository(database: database).saveSettings(settings)
        let app = AppState(database: database, permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            systemAudioCaptureService: fixture.capture, dialogueDefaults: defaults)
        // This failure case needs no timing latch. Opening the synthetic native
        // stop gate before use guarantees owning-test cancellation cannot strand
        // the test host while the deliberate stop error is checked.
        fixture.stream.stopGate.open()
        var cleanupAtPublication: [Bool] = []
        let observer = app.objectWillChange.sink { _ in
            cleanupAtPublication.append(app.captureLifecycle.hasFailedTeardown)
        }
        defer { observer.cancel() }
        do {
            let session = try app.sessionRepository.createSession(mode: .microphone)
            _ = try await fixture.provider.startTranscription(config: config(session.id))
            app.currentSession = session
            app.activeASRProviderRuntime = fixture.provider
            app.markActiveASRProvider(.localParakeet)
            app.markSystemAudioCaptureRuntimeOwnedForTesting(true)
            app.liveState = .listening
            app.currentCaptureRuntimeState = .listening
            fixture.stream.stopFailure = FixtureFailure.nativeStop
            app.stopListening(reason: .userRequested)
            let failedControl = try #require(app.captureTeardownTask)
            await failedControl.value
            #expect(app.activeASRProviderRuntime == nil,
                "The UI has retired this provider, so shutdown must use retained teardown authority.")
            #expect(fixture.provider.captureCleanupFailure != nil)
            #expect(fixture.stream.running)
            #expect(fixture.stream.stopCalls == 1)
            #expect(app.captureLifecycle.hasFailedTeardown)
            #expect(app.canStopCapture)
            #expect(app.primaryHomeActionShouldStop,
                "Stopped UI must keep the existing Stop action available for retained cleanup.")
            #expect(cleanupAtPublication.contains(true),
                "The actual App observer must see committed failed ownership, not only pre-commit error publication.")
            let firstShutdown = await app.shutdownResources()
            #expect(!firstShutdown,
                "A completed failed control Task is not proof that its retired native resource was released.")
            #expect(fixture.stream.running)
            let callsAfterFirstShutdown = fixture.stream.stopCalls
            fixture.stream.stopFailure = nil
            let publicationsBeforeRetry = cleanupAtPublication.count
            let retryShutdown = await app.shutdownResources()
            #expect(retryShutdown,
                "A later explicit shutdown must retry the same retained provider operation, not lose it after the public slot was cleared.")
            #expect(!fixture.stream.running)
            #expect(!fixture.runtime.running)
            #expect(fixture.stream.stopCalls == callsAfterFirstShutdown + 1,
                "One later explicit retry must issue exactly one additional stop on the retained original native resource.")
            #expect(fixture.provider.captureCleanupFailure == nil)
            #expect(!app.captureLifecycle.hasFailedTeardown)
            #expect(app.captureLifecycle.pendingTaskCount == 0)
            #expect(!app.canStopCapture)
            #expect(!app.primaryHomeActionShouldStop)
            #expect(cleanupAtPublication.dropFirst(publicationsBeforeRetry).contains(false),
                "Successful exact retry must invalidate the UI after clearing failed ownership.")
            await fixture.cleanup()
            await app.shutdownForTesting()
            defaults.removePersistentDomain(forName: suite)
            try database.close()
        } catch {
            await fixture.cleanup()
            await app.shutdownForTesting()
            defaults.removePersistentDomain(forName: suite)
            try? database.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func appStopTraceDistinguishesRequestCloseFromFrozenNativeCleanupResult() async throws {
        let fixture = NativeFixture()
        let database = try AppDatabase(inMemory: true)
        let suite = "com.langcheng.Hireva.tests.cleanup-trace." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        var settings = AppSettings.default
        settings.saveTranscriptsLocally = false
        settings.audioCaptureMode = .systemAudioOnly
        settings.automaticQuestionDetectionEnabled = false
        settings.manualOnlyMode = true
        settings.diagnosticTraceMode = .off
        try SettingsRepository(database: database).saveSettings(settings)
        let app = AppState(database: database, permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            systemAudioCaptureService: fixture.capture, dialogueDefaults: defaults)
        // Deliberate native errors require no held worker. The test owns an
        // already-open fake stop gate, including every failure cleanup path.
        fixture.stream.stopGate.open()
        do {
            let legacy = TranscriptRuntimeEventRecord(timestamp: Date(), name: "synthetic-legacy", sessionID: "legacy")
            let legacyMetadataLine = try #require(legacy.jsonLine(for: .metadataOnly))
            let legacyMetadata = try #require(JSONSerialization.jsonObject(with: Data(legacyMetadataLine.utf8)) as? [String: Any])
            let legacyFullLine = try #require(legacy.jsonLine(for: .fullText))
            let legacyFull = try #require(JSONSerialization.jsonObject(with: Data(legacyFullLine.utf8)) as? [String: Any])
            #expect(legacyMetadata["captureTeardownID"] == nil)
            #expect(legacyFull["capture_teardown_id"] == nil)
            let original = try app.sessionRepository.createSession(mode: .microphone)
            let replacement = try app.sessionRepository.createSession(mode: .microphone)
            _ = try await fixture.provider.startTranscription(config: config(original.id))
            app.currentSession = original
            app.activeASRProviderRuntime = fixture.provider
            app.markActiveASRProvider(.localParakeet)
            app.markSystemAudioCaptureRuntimeOwnedForTesting(true)
            app.liveState = .listening
            app.currentCaptureRuntimeState = .listening
            fixture.stream.stopFailure = FixtureFailure.nativeStop

            app.stopListening(reason: .userRequested)
            let stoppedControl = try #require(app.captureTeardownTask)
            let originalID = try #require(app.captureTeardownID).uuidString
            #expect(!app.diagnosticsState.recentEvents.contains { $0.name == "capture.stop.completed" },
                "Closing the synchronous stop request is not native cleanup completion.")
            #expect(app.diagnosticsState.recentEvents.contains { $0.name == "capture.stop.request.closed" })
            #expect(!app.diagnosticsState.recentEvents.contains { $0.name == "capture.cleanup.operation.completed" })

            // Replace the visible session before the first exact cleanup body
            // runs. Audit results must retain the submitted session without
            // assigning its old identity/error to the current runtime snapshot.
            app.currentSession = replacement
            var currentRuntime = TranscriptRuntimeDiagnostics.empty
            currentRuntime.audioSessionID = replacement.id
            currentRuntime.recordAudioBufferBatch(count: 3, source: .systemAudio)
            currentRuntime.lastGenerationRejectedReason = "synthetic-current-rejection"
            app.diagnosticsState.runtime = currentRuntime
            await stoppedControl.value
            #expect(app.diagnosticsState.runtime == currentRuntime)
            #expect(fixture.stream.running)
            #expect(fixture.stream.stopCalls == 1)
            let failures = app.diagnosticsState.recentEvents.filter { $0.name == "capture.cleanup.operation.failed" }
            #expect(failures.count == 1)
            if let failure = failures.first {
                #expect(failure.sessionID == original.id)
                let metadataLine = try #require(failure.jsonLine(for: .metadataOnly))
                let metadata = try #require(JSONSerialization.jsonObject(with: Data(metadataLine.utf8)) as? [String: Any])
                #expect(metadata["captureTeardownID"] as? String == originalID)
                #expect(metadata["sessionID"] as? String == original.id)
                #expect(metadata["generationID"] as? String == "")
                #expect(metadata["rawText"] == nil)
                #expect(failure.text.isEmpty && failure.uiTranscriptText.isEmpty && failure.visibleQuestionText.isEmpty)
            }

            fixture.stream.stopFailure = nil
            app.stopListening(reason: .userRequested)
            let retriedControl = try #require(app.captureTeardownTask)
            let replacementCleanupID = try #require(app.captureTeardownID).uuidString
            #expect(replacementCleanupID != originalID)
            app.diagnosticsState.runtime = currentRuntime
            await retriedControl.value
            await app.captureLifecycle.drain()
            #expect(app.diagnosticsState.runtime == currentRuntime)
            #expect(!fixture.stream.running)
            #expect(fixture.stream.stopCalls == 2)
            let completions = app.diagnosticsState.recentEvents.filter { $0.name == "capture.cleanup.operation.completed" }
            #expect(completions.count == 2,
                "The retained original and the later empty stop each report their own committed operation result.")
            var completedIdentities: [String: String] = [:]
            for result in completions {
                let metadataLine = try #require(result.jsonLine(for: .metadataOnly))
                let metadata = try #require(JSONSerialization.jsonObject(with: Data(metadataLine.utf8)) as? [String: Any])
                if let identity = metadata["captureTeardownID"] as? String {
                    completedIdentities[identity] = result.sessionID
                }
                let fullLine = try #require(result.jsonLine(for: .fullText))
                let full = try #require(JSONSerialization.jsonObject(with: Data(fullLine.utf8)) as? [String: Any])
                #expect(full["capture_teardown_id"] as? String == metadata["captureTeardownID"] as? String)
            }
            #expect(completedIdentities[originalID] == original.id)
            #expect(completedIdentities[replacementCleanupID] == replacement.id)
            #expect(!app.captureLifecycle.hasFailedTeardown)
            #expect(app.captureLifecycle.pendingTaskCount == 0)
            await fixture.cleanup()
            await app.shutdownForTesting()
            defaults.removePersistentDomain(forName: suite)
            try database.close()
        } catch {
            await fixture.cleanup()
            await app.shutdownForTesting()
            defaults.removePersistentDomain(forName: suite)
            try? database.close()
            throw error
        }
    }

    private func config(_ session: String) -> ASRConfig {
        ASRConfig(sessionID: session, captureMode: .systemAudioOnly)
    }

    private enum FixtureFailure: Error, Equatable { case nativeStop, exhaustedFactory }

    @MainActor
    private final class NativeFixture {
        let stream: NativeStream
        let runtime: NativeRuntime
        let releaseOnJoin: StopReleasePolicy
        let capture: ScreenCaptureKitSystemAudioCaptureService
        let provider: LocalParakeetASRProvider

        init() {
            let stream = NativeStream()
            let runtime = NativeRuntime()
            let release = StopReleasePolicy(streams: [stream])
            let capture = ScreenCaptureKitSystemAudioCaptureService(
                streamFactory: { stream }, onFinishStoppingEntered: { release.joinEntered() }
            )
            self.stream = stream
            self.runtime = runtime
            releaseOnJoin = release
            self.capture = capture
            provider = LocalParakeetASRProvider(modelManager: InstalledModelManager(),
                runtimeClient: runtime, systemAudioCaptureService: capture)
        }

        func run<Result>(_ body: @MainActor () async throws -> Result) async throws -> Result {
            do {
                let result = try await body()
                await cleanup()
                return result
            } catch {
                await cleanup()
                throw error
            }
        }

        func cleanup() async {
            releaseOnJoin.openAll()
            await provider.stopTranscription()
            _ = try? await capture.finishStoppingSystemAudioCapture()
            // A failed fake stop deliberately leaves the physical stand-in alive.
            // The test owns it and explicitly releases it after checking failure.
            stream.stopFailure = nil
            if stream.running { try? await stream.stopCapture() }
            #expect(!stream.running)
            #expect(!runtime.running)
        }
    }

    @MainActor
    private final class NativeStream: SystemAudioCaptureStream {
        let stopGate = Gate()
        var stopFailure: Error?
        private(set) var running = false
        private(set) var stopCalls = 0
        init() { stopGate.open() }
        func startCapture() async throws { running = true }
        func stopCapture() async throws {
            stopCalls += 1
            await stopGate.wait()
            if let stopFailure { throw stopFailure }
            running = false
        }
    }

    @MainActor
    private final class StopReleasePolicy {
        let streams: [NativeStream]
        var armed = false {
            didSet {
                // A later replacement has not acquired native capture yet.
                // Hold only the successfully started stream under test.
                if armed && !oldValue {
                    streams.filter { $0.running }.forEach { $0.stopGate.close() }
                }
            }
        }
        init(streams: [NativeStream]) { self.streams = streams }
        func joinEntered() { if armed { openAll() } }
        func openAll() { streams.forEach { $0.stopGate.open() } }
    }

    @MainActor
    private final class StreamFactory {
        let streams: [NativeStream]
        private var index = 0
        private(set) var startedBeforePreviousExit = false
        init(streams: [NativeStream]) { self.streams = streams }
        func next() throws -> NativeStream {
            guard streams.indices.contains(index) else { throw FixtureFailure.exhaustedFactory }
            if index > 0 { startedBeforePreviousExit = startedBeforePreviousExit || streams[index - 1].running }
            let stream = streams[index]
            index += 1
            return stream
        }
    }

    @MainActor
    private final class NativeRuntime: ParakeetRuntimeClient {
        var cleanupFailure: Error?
        private(set) var running = false
        private(set) var startCalls = 0
        private var continuation: AsyncThrowingStream<ParakeetTranscriptEvent, Error>.Continuation?
        func isRuntimeAvailable() async -> Bool { true }
        func startTranscription(modelDirectory: URL, config: ASRConfig) async throws -> AsyncThrowingStream<ParakeetTranscriptEvent, Error> {
            startCalls += 1
            running = true
            let pair = AsyncThrowingStream<ParakeetTranscriptEvent, Error>.makeStream()
            continuation = pair.continuation
            return pair.stream
        }
        func finish() { continuation?.finish() }
        func stop() async { continuation?.finish(); running = false }
        nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {}
    }

    private final class InstalledModelManager: LocalModelManager {
        func modelStatus(_ model: LocalModelDescriptor) async -> LocalModelStatus { .installed }
        func downloadModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> { AsyncThrowingStream { $0.finish() } }
        func deleteModel(_ model: LocalModelDescriptor) async throws {}
        func verifyModel(_ model: LocalModelDescriptor) async throws -> Bool { true }
        func fileURL(for model: LocalModelDescriptor) -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-native-stop-model")
        }
    }

    @MainActor
    private final class Gate {
        private var opened = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private let entry = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        private let entryTrace = TestEventWaitTrace(label: "parakeet_exact_native_stop_entered")
        func wait() async {
            entry.continuation.yield(())
            entry.continuation.finish()
            if opened { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func waitUntilEntered() async throws {
            _ = try await entryTrace.nextEvent(in: entry.stream, event: "native_stop_entered")
        }
        func open() {
            opened = true
            let pending = waiting; waiting.removeAll()
            pending.forEach { $0.resume() }
        }
        func close() {
            precondition(waiting.isEmpty)
            opened = false
        }
    }
}
