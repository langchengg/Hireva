import Foundation
import Testing
@testable import Hireva

/// Exercises the current constructor and actual native-service publishers with
/// isolated preferences/database. No SCStream, device, models or network is used.
@MainActor
struct AppRuntimeAssemblyCharacterizationTests {
    @Test(.timeLimit(.minutes(1)))
    func constructorKeepsStoredSelectionAndSuppressesNativeTestStartup() async throws {
        let database = try AppDatabase(inMemory: true)
        let suite = "com.langcheng.Hireva.tests.runtime-assembly-startup." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var stored = AppSettings.default
        stored.audioCaptureMode = .systemAudioOnly
        try SettingsRepository(database: database).saveSettings(stored)
        defaults.set(ASRProviderID.localParakeet.rawValue, forKey: HirevaPreferenceKeys.selectedASRProvider)
        defaults.set(ASRProviderID.localParakeet.rawValue, forKey: HirevaPreferenceKeys.activeASRProvider)
        defaults.set("synthetic-runtime-assembly-model", forKey: HirevaPreferenceKeys.selectedQwenModel)
        defaults.set(AnswerProviderMode.localQwenPrimary.rawValue, forKey: HirevaPreferenceKeys.answerProviderMode)
        let capture = ScreenCaptureKitSystemAudioCaptureService()
        let app = makeApp(database: database, defaults: defaults, capture: capture)
        do {
            #expect(isRunningUnderTestOrAutomation())
            #expect(app.settings.audioCaptureMode == .systemAudioOnly)
            #expect(app.selectedASRProviderID == .localParakeet,
                "The native launch-only ASR migration stays suppressed in ordinary tests.")
            #expect(app.selectedQwenModelName == "synthetic-runtime-assembly-model")
            #expect(app.selectedAnswerProviderMode == .localQwenPrimary)
            #expect(defaults.string(forKey: HirevaPreferenceKeys.activeASRProvider) == nil,
                "The stale active-provider identity is still cleared during construction.")
            #expect(app.audioDeviceRouteMonitor == nil)
            #expect(app.liveSystemAudioDiagnosticObserverToken == nil)
            #expect(app.automaticContextBuildTask == nil)
            #expect(app.systemAudioCaptureService === capture)
            #expect(!capture.isCapturing)
            #expect(capture.lastBufferReceivedAt == nil)
            #expect(await app.shutdownResources())
            try database.close()
        } catch {
            await app.shutdownForTesting()
            try? database.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func captureErrorRelayDropsInitialValueAndIsRemovedByOwnedShutdown() async throws {
        let database = try AppDatabase(inMemory: true)
        let suite = "com.langcheng.Hireva.tests.runtime-assembly-relay." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let capture = ScreenCaptureKitSystemAudioCaptureService()
        let initial = "synthetic error present before constructor subscriptions"
        let updated = "synthetic error through the assembled live publisher"
        let late = "synthetic error after application-owned shutdown"
        capture.lastError = initial
        let app = makeApp(database: database, defaults: defaults, capture: capture)
        let delivered = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(4))
        let trace = TestEventWaitTrace(label: "composition-native-error-relay")
        var observations: [String] = []
        app.systemAudioErrorDidObserve = { error in
            #expect(Thread.isMainThread, "The existing receive(on: main) contract must be preserved.")
            if let error {
                observations.append(error)
                delivered.continuation.yield(error)
            }
        }
        @MainActor func cleanup() async {
            app.systemAudioErrorDidObserve = nil
            delivered.continuation.finish()
            await app.shutdownForTesting()
            try? database.close()
        }
        try await withTaskCancellationHandler {
            do {
                await flushMainQueue()
                #expect(observations.isEmpty,
                    "dropFirst prevents replaying the publisher's pre-construction diagnostic.")
                capture.lastError = updated
                #expect(try await trace.nextEvent(in: delivered.stream, event: "current-error") == updated)
                #expect(observations == [updated])
                #expect(app.currentCaptureRuntimeState == .idle,
                    "An unowned capture diagnostic cannot grant terminal capture authority.")
                #expect(await app.shutdownResources())
                capture.lastError = late
                await flushMainQueue()
                #expect(observations == [updated],
                    "Shutdown must cancel the exact assembled sink before returning.")
                #expect(capture.lastError == late)
                app.systemAudioErrorDidObserve = nil
                delivered.continuation.finish()
                try database.close()
            } catch {
                await cleanup()
                throw error
            }
        } onCancel: { delivered.continuation.finish() }
    }

    private func makeApp(database: AppDatabase, defaults: UserDefaults,
        capture: ScreenCaptureKitSystemAudioCaptureService) -> AppState {
        AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            systemAudioCaptureService: capture, verificationMocksEnabled: false,
            dialogueDefaults: defaults)
    }

    /// A finite scheduler barrier, not a longer sleep or a native stop proof.
    private func flushMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
