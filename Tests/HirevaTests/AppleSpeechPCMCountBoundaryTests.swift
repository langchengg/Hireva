import Combine
import Foundation
import Testing
@testable import Hireva

@MainActor
struct AppleSpeechPCMCountBoundaryTests {
    @Test(arguments: [64, 128])
    func anActualRuntimeBatchPreservesItsExactPCMCountWithoutPerBufferPublication(bufferCount: Int) async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()), dialogueDefaults: nil)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        app.recordTranscriptRuntimeEvent(.audioStarted(sessionID: "synthetic-pcm-batch", timestamp: now))
        var publications = 0
        let observer = app.diagnosticsState.objectWillChange.sink { publications += 1 }
        let batch = TranscriptRuntimeEvent.audioBufferReceived(sessionID: "synthetic-pcm-batch",
            frameCount: 960 * bufferCount, timestamp: now.addingTimeInterval(1), bufferCount: bufferCount, source: .systemAudio)
        app.recordTranscriptRuntimeEvent(batch)
        #expect(app.transcriptRuntimeDiagnostics.audioBufferCount == bufferCount)
        #expect(app.totalSystemAudioASRBuffersAppended == bufferCount)
        #expect(app.transcriptRuntimeDiagnostics.lastAudioBufferAt == now.addingTimeInterval(1))
        #expect(publications == 0)
        #expect(!app.diagnosticsState.recentEvents.contains { $0.name == "audioBufferReceived" })
        let metadata = try #require(batch.record.jsonLine(for: .metadataOnly)?.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        #expect(object["bufferCount"] as? Int == bufferCount)
        #expect(object["frameCount"] as? Int == 960 * bufferCount)
        // Existing one-buffer callers keep the default contract unchanged.
        app.recordTranscriptRuntimeEvent(.audioBufferReceived(sessionID: "synthetic-pcm-batch",
            frameCount: 960, timestamp: now.addingTimeInterval(2), source: .systemAudio))
        #expect(app.transcriptRuntimeDiagnostics.audioBufferCount == bufferCount + 1)
        #expect(app.totalSystemAudioASRBuffersAppended == bufferCount + 1)
        #expect(publications == 0)
        observer.cancel()
        await app.shutdownForTesting()
        try database.close()
    }
}
