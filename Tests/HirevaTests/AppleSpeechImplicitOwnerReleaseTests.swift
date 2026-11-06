import Foundation
import Testing
@testable import Hireva

/// Implicit release is not a substitute for native stop/join. These tests own
/// every escaped input/control/display handle and release them after red checks.
@MainActor
struct AppleSpeechImplicitOwnerReleaseTests {
    @Test(.timeLimit(.minutes(1)))
    func releasingActualSessionClosesItsInputAndLetsItsOwnedDisplayWorkerExit() async throws {
        var session: AppleSpeechTranscriptionSession? = .init(sessionID: .init(source: .microphone),
            parentSessionID: "synthetic-session-implicit-release", onEmit: { _ in }, onStateChange: {},
            pcmTestingOperations: .init(append: { _ in }, endAudio: {}))
        var input: AppleSpeechPCMInput?
        var displays: [Task<Void, Never>] = []
        @MainActor func cleanup() async {
            if let session { session.stop(); await session.finishStoppingAudioInput() }
            let close = input?.close()
            await close?.value
            for task in displays { await task.value }
            session = nil
        }
        do {
            session?.startSimulatedRecognitionForDiagnostic()
            let requiredSessionPCMInput: AppleSpeechPCMInput = try #require(session?.nativePCMInput)
            input = requiredSessionPCMInput
            displays = try #require(session?.ownedPCMDisplayTasksForTesting)
            #expect(displays.count == 1)
            weak var weakSession = session
            session = nil
            #expect(weakSession == nil)
            #expect(input?.isAcceptingForTesting == false,
                "Released Session must close its actual input, not strand its weak-self display worker.")
            // Cleanup is unconditional even on the unfixed implementation. The
            // red assertion never awaits the defect that it is demonstrating.
            await cleanup()
            #expect(input?.hasUnreleasedInput == false)
        } catch { await cleanup(); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func releasingActualServiceClosesItsReceiverAndLetsOwnedControlAndDisplayWorkersExit() async throws {
        var service: AppleSpeechTranscriptionService? = .init(
            stopTestingOperations: .init(unregisterMicrophone: { _ in },
                unregisterSystemAudio: { _ in }, stopSystemAudio: {}),
            pcmTestingOperations: .init(append: { _ in }, endAudio: {}))
        var input: AppleSpeechPCMInput?
        var displays: [Task<Void, Never>] = []
        var controls: [(controls: AppleSpeechNativeControlIngress, task: Task<Void, Never>)] = []
        @MainActor func cleanup() async {
            if let service { service.stop(); await service.finishStoppingAudioInput() }
            for entry in controls { entry.controls.close() }
            let close = input?.close()
            await close?.value
            for task in displays { await task.value }
            for entry in controls { await entry.task.value }
            service = nil
        }
        do {
            service?.startDiagnosticSystemAudioSession(sessionID: "synthetic-service-implicit-release")
            let requiredServicePCMInput: AppleSpeechPCMInput = try #require(service?.systemAudioSession?.nativePCMInput)
            input = requiredServicePCMInput
            displays = try #require(service?.systemAudioSession?.ownedPCMDisplayTasksForTesting)
            controls = try #require(service?.ownedNativeControlWorkersForTesting)
            #expect(displays.count == 1)
            #expect(controls.count == 1)
            weak var weakService = service
            service = nil
            #expect(weakService == nil)
            #expect(controls.allSatisfy { !$0.controls.isAccepting },
                "Released Service must finish the actual receiver signal, not strand its weak-self control worker.")
            #expect(input?.isAcceptingForTesting == false)
            // Captured handles are exact old resources. Finish and join on red
            // as well as green; no unowned release or observer Task is needed.
            await cleanup()
            #expect(input?.hasUnreleasedInput == false)
        } catch { await cleanup(); throw error }
    }
}
