import Foundation
import Testing
@testable import Hireva

/// Exercises the shared hermetic provider used by real App/Live tests. This
/// protects fixture ownership and does not stand in for device ASR acceptance.
@MainActor
struct HermeticASRRoundIdentityTests {
    @Test(.timeLimit(.minutes(1)))
    func cancellingAnOldConsumerCannotClearTheReplacementContinuation() async throws {
        let provider = HermeticTestASRProvider()
        let observed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let trace = TestEventWaitTrace(label: "hermetic.asr.old-consumer")
        var oldConsumer: Task<Void, Error>?
        var replacementConsumer: Task<[TranscriptSegment], Error>?
        do {
            let oldStream = try await provider.startTranscription(config: .init(
                sessionID: "old-fixture-round", captureMode: .systemAudioOnly))
            let old = Task {
                for try await segment in oldStream {
                    if segment.id == "old-consumer-entered" { observed.continuation.yield(()) }
                }
            }
            oldConsumer = old
            provider.emit(text: "Synthetic old stream.", sessionID: "old-fixture-round",
                isFinal: true, segmentID: "old-consumer-entered")
            _ = try await trace.nextEvent(in: observed.stream, event: "old-consumer-observed")

            let replacementStream = try await provider.startTranscription(config: .init(
                sessionID: "replacement-fixture-round", captureMode: .systemAudioOnly))
            let replacement = Task {
                var values: [TranscriptSegment] = []
                for try await value in replacementStream { values.append(value) }
                return values
            }
            replacementConsumer = replacement
            old.cancel()
            _ = await old.result
            let replacementStillOwned = provider.hasActiveContinuationForTesting
            #expect(replacementStillOwned,
                "The actual old stream termination must not erase the newer fixture continuation.")
            if replacementStillOwned {
                provider.emit(text: "Synthetic replacement stream.", sessionID: "replacement-fixture-round",
                    isFinal: true, segmentID: "replacement-final")
                await provider.stopTranscription()
                let values = try await replacement.value
                #expect(values.map(\.id) == ["replacement-final"])
                #expect(values.map(\.sessionID) == ["replacement-fixture-round"])
                #expect(!provider.hasActiveContinuationForTesting)
            } else {
                // A real baseline failure must remain an immediate assertion,
                // then release/join the unreachable stream instead of hanging.
                replacement.cancel()
                _ = await replacement.result
                await provider.stopTranscription()
            }
            observed.continuation.finish()
        } catch {
            oldConsumer?.cancel()
            replacementConsumer?.cancel()
            await provider.stopTranscription()
            _ = await oldConsumer?.result
            _ = await replacementConsumer?.result
            observed.continuation.finish()
            throw error
        }
    }
}
