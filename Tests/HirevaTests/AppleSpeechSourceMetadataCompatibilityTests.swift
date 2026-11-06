import Foundation
import Testing
@testable import Hireva

/// Additive diagnostic source metadata; omitted source stays unknown and never
/// becomes a candidate/interviewer role or fabricated system input count.
@MainActor
struct AppleSpeechSourceMetadataCompatibilityTests {
    @Test(.timeLimit(.minutes(1)))
    func legacyUntypedPCMRemainsUnattributedAndStoppedDisplayIsZero() async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()), dialogueDefaults: nil)
        @MainActor func cleanup() async { await app.shutdownForTesting(); try? database.close() }
        do {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let legacy = TranscriptRuntimeEvent.audioBufferReceived(sessionID: "synthetic-legacy-source",
                frameCount: 960, timestamp: now)
            app.recordTranscriptRuntimeEvent(legacy)
            #expect(app.transcriptRuntimeDiagnostics.audioBufferCount == 1)
            #expect(app.transcriptRuntimeDiagnostics.unattributedAudioBufferCount == 1)
            #expect(app.totalSystemAudioASRBuffersAppended == 0)
            #expect(legacy.record.audioSource == nil)
            app.recordTranscriptRuntimeEvent(.audioBufferReceived(sessionID: "synthetic-legacy-source",
                frameCount: 3840, timestamp: now.addingTimeInterval(1), bufferCount: 4, source: .systemAudio))
            #expect(app.transcriptRuntimeDiagnostics.audioBufferCount == 5)
            #expect(app.transcriptRuntimeDiagnostics.bufferCount(for: .systemAudio) == 4)
            #expect(app.totalSystemAudioASRBuffersAppended == 4)
            // This is the real Diagnostics stop hook used by App.stopListening.
            app.markRuntimeAudioStopped()
            #expect(app.totalSystemAudioASRBuffersAppended == 0)
            #expect(app.transcriptRuntimeDiagnostics.audioBufferCount == 5)
            #expect(app.transcriptRuntimeDiagnostics.bufferCount(for: .systemAudio) == 4)
            #expect(app.transcriptRuntimeDiagnostics.unattributedAudioBufferCount == 1)
            await cleanup()
        }
    }

    @Test
    func optionalSourceMetadataPreservesLegacyShapeAndRecordsExplicitOriginWithoutSpeakerInference() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = TranscriptRuntimeEvent.audioBufferReceived(sessionID: "synthetic-source-json",
            frameCount: 960, timestamp: now)
        let typed = TranscriptRuntimeEvent.audioBufferReceived(sessionID: "synthetic-source-json",
            frameCount: 960, timestamp: now, source: .microphone)
        let legacyMetadata = try object(legacy.record, mode: .metadataOnly)
        let typedMetadata = try object(typed.record, mode: .metadataOnly)
        let legacyFull = try object(legacy.record, mode: .fullText)
        let typedFull = try object(typed.record, mode: .fullText)
        #expect(legacyMetadata["audioSource"] == nil)
        #expect(legacyFull["audio_source"] == nil)
        #expect(typedMetadata["audioSource"] as? String == AudioSourceType.microphone.rawValue)
        #expect(typedFull["audio_source"] as? String == AudioSourceType.microphone.rawValue)
        #expect(legacyMetadata["bufferCount"] as? Int == 1)
        #expect(typedMetadata["bufferCount"] as? Int == 1)
        #expect(typedMetadata["speaker"] == nil)
        #expect(typedFull["speaker"] == nil)
        #expect(typed.record.redactedForMetadata().audioSource == .microphone)
    }

    private func object(_ record: TranscriptRuntimeEventRecord, mode: DiagnosticTraceMode) throws -> [String: Any] {
        let data = try #require(record.jsonLine(for: mode)?.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
