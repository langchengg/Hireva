import Foundation
import Testing
@testable import Hireva

@MainActor
struct CurrentTimerCallbackResourceTests {
    // Stage only the two-line visibility/access characterization first.
    // This file invokes the CURRENT actual production Timer bridge, not a
    // copied callback. It should fail before the owner makes delivery lexical.
    @Test(.timeLimit(.minutes(1)))
    func actualCurrentTimerCallbackMustNotEscapeItsEpochIntoAnotherTask() async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()))
        do {
            await app.startAudioSignalMonitoring()
            let timer = try #require(app.audioSignalMonitoringTimer)
            #expect(timer.timeInterval == 1.0)
            app.systemASRTaskRunning = true
            // The idle-state monitoring branch reads no microphone/global
            // engine: the real ASR diagnostic assignment is observable here.
            timer.fire()
            #expect(app.systemASRTaskRunning == false,
                "A timer tick must execute in its owned installation epoch, without an unretained queued Task.")
            app.stopAudioSignalMonitoring()
            #expect(!timer.isValid)
            await app.shutdownForTesting(); try database.close()
        } catch {
            app.stopAudioSignalMonitoring(); await app.shutdownForTesting()
            try? database.close(); throw error
        }
    }
}
