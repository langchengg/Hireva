#if DEBUG
import Combine
import Foundation
import Testing
@testable import Hireva

/// Both arguments exercise actual Diagnostics entry points. Runtime is a plain
/// struct in the reviewed source: only recentEvents publishes during these
/// calls. These are GREEN characterizations of v2, not a claimed v2 regression.
@MainActor
struct RuntimeTraceBusinessURLCharacterizationTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func displayObserverCannotRedirectAuditOrBusinessFinal(recordsBusinessFinal: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaTraceURLCharacterization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let store = RuntimeTranscriptTraceStore()
        let originalURL = root.appendingPathComponent("original.jsonl")
        let replacementURL = root.appendingPathComponent("replacement.jsonl")
        let owner = DiagnosticsState(traceLogURL: originalURL, traceStore: store)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let expectedName = recordsBusinessFinal ? "asrFinal" : "capture.cleanup.operation.completed"
        let sessionID = "synthetic-frozen-record-scope"
        var notificationCount = 0
        var runtimeFinalCountAtNotification: Int?
        let observation = owner.objectWillChange.sink {
            notificationCount += 1
            if notificationCount == 1 {
                runtimeFinalCountAtNotification = owner.runtime.finalTranscriptCount
                owner.traceLogURL = replacementURL
            }
        }
        @MainActor func cleanup() async {
            observation.cancel()
            await owner.shutdown()
            // This barrier belongs only to the private fixture store; the test
            // never closes/seals/waits on the application's shared store.
            await store.finishPendingOperationsForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        do {
            if recordsBusinessFinal {
                owner.record(.asrFinal(sessionID: sessionID, text: "",
                    recognitionTaskID: "synthetic-asr", eventSequence: 1,
                    sourceStartUTF16: 0, sourceEndUTF16: 0, isFinal: true,
                    timestamp: timestamp), context: .init(), mode: .metadataOnly)
            } else {
                owner.recordCaptureCleanupResult(sessionID: sessionID,
                    teardownID: UUID(), released: true, mode: .metadataOnly)
            }
            observation.cancel()
            await store.finishPendingOperationsForTesting()
            #expect(notificationCount == 1,
                "The reviewed plain runtime does not publish before the recent-event update.")
            #expect(runtimeFinalCountAtNotification == (recordsBusinessFinal ? 1 : 0))
            #expect(owner.runtime.finalTranscriptCount == (recordsBusinessFinal ? 1 : 0))
            #expect(owner.runtime.audioSessionID == (recordsBusinessFinal ? sessionID : ""))
            #expect(owner.recentEvents.count == 1)
            #expect(owner.recentEvents.last?.name == expectedName)
            #expect(owner.recentEvents.last?.sessionID == sessionID)
            #expect(owner.traceLogURL == replacementURL)
            #expect(FileManager.default.fileExists(atPath: originalURL.path))
            #expect(!FileManager.default.fileExists(atPath: replacementURL.path),
                "Synchronous display reentry cannot move either actual entry's admitted event to the next URL.")
            let contents = try String(contentsOf: originalURL, encoding: .utf8)
            let lines = contents.split(separator: "\n")
            #expect(lines.count == 1)
            let line = try #require(lines.first)
            let json = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect(json["eventType"] as? String == expectedName)
            #expect(json["sessionID"] as? String == sessionID)
            if recordsBusinessFinal {
                #expect(owner.runtime.lastASRFinalAt == timestamp)
                #expect(owner.recentEvents.last?.recognitionIsFinal == true)
            }
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }
}
#endif
