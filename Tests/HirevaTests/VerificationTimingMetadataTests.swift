import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Hireva

// No capture, native process, provider, preferences or global environment.
struct VerificationTimingMetadataTests {
    @Test
    func ordinaryTestHostDoesNotEnableVerificationTiming() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "HirevaVerificationOnly") as? Bool != true)
        #expect(!VerificationTiming.enabled)
        #expect(VerificationTiming.hostTicks() == nil)
    }

    @Test
    func legacyTranscriptHasNoManufacturedProducerTime() throws {
        var value = TranscriptSegment(id: "synthetic-segment", sessionID: "synthetic-session",
            source: .systemAudio, speaker: .unknown, text: "Synthetic statement.")
        let legacy = try JSONEncoder().encode(value)
        let object = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        #expect(object["verificationFinalHostTicks"] == nil)
        #expect(try JSONDecoder().decode(TranscriptSegment.self, from: legacy).verificationFinalHostTicks == nil)
        value.verificationFinalHostTicks = 123
        let restored = try JSONDecoder().decode(TranscriptSegment.self, from: JSONEncoder().encode(value))
        #expect(restored.verificationFinalHostTicks == 123)
        #expect(restored.text == value.text && restored.id == value.id && restored.sessionID == value.sessionID)
    }

    @Test
    func legacyDecisionAndRetrievalTraceKeepNilOptionalTimes() throws {
        var decision = InterviewQuestionDecision(task: .generalKnowledge, personalEvidence: .notRequired,
            basis: .generalKnowledge, relation: .independent, parentQuestionID: nil,
            parentQuestionText: nil, parentAnswerText: nil, source: "synthetic",
            routerVersion: "synthetic-frozen", language: "en", clarification: "", questionID: "synthetic-question",
            questionRevision: 2, contextSnapshotID: "synthetic-context", artifactRevision: 3,
            model: "synthetic-model", failure: nil, latencyMS: 1)
        let data = try JSONEncoder().encode(decision)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["verificationCompletedHostTicks"] == nil)
        let old = try JSONDecoder().decode(InterviewQuestionDecision.self, from: data)
        #expect(old.verificationCompletedHostTicks == nil && old.questionRevision == 2 && old.artifactRevision == 3)
        decision.verificationCompletedHostTicks = 456
        #expect(try JSONDecoder().decode(InterviewQuestionDecision.self,
            from: JSONEncoder().encode(decision)).verificationCompletedHostTicks == 456)
        var trace = RetrievalTrace(id: UUID(), query: "synthetic query", intent: nil, createdAt: Date(),
            rankedCVChunks: [], rankedJDChunks: [], includedCVChunks: [], includedJDChunks: [],
            excludedCVChunks: [], excludedJDChunks: [], cvWordsUsed: 0, jdWordsUsed: 0,
            cvWordBudget: 1, jdWordBudget: 1, retrievalLatencyMS: 1,
            emptyQueryFallbackUsed: false, zeroScoreFallbackUsed: false)
        let traceData = try JSONEncoder().encode(trace)
        let traceObject = try #require(JSONSerialization.jsonObject(with: traceData) as? [String: Any])
        #expect(traceObject["verificationCompletedHostTicks"] == nil)
        #expect(try JSONDecoder().decode(RetrievalTrace.self, from: traceData).verificationCompletedHostTicks == nil)
        trace.verificationCompletedHostTicks = 789
        #expect(try JSONDecoder().decode(RetrievalTrace.self,
            from: JSONEncoder().encode(trace)).verificationCompletedHostTicks == 789)
    }

    @Test(arguments: [false, true])
    func numericEnergyObservationPreservesStereoStride(interleaved: Bool) throws {
        let buffer = try stereoBuffer(interleaved: interleaved, frames: 4)
        let channels = try #require(buffer.floatChannelData)
        channels[0][2 * buffer.stride] = 0.2
        channels[0][3 * buffer.stride] = 0.001 // below frozen mean-power threshold
        let leaf = testLeaf()
        leaf.observe(buffer, pts: CMTime(value: 48_000, timescale: 48_000), nativeSampleCount: 4,
            callbackSourceIdentity: "synthetic-capture-receipt", captureRevision: 7, hostBefore: 123)
        let batch = try #require(leaf.takeBatch())
        let anchor = try #require(batch.anchors.first)
        #expect(batch.anchors.count == 1 && batch.clockDomain == "unit-test-context")
        #expect(anchor.lastFrameAboveThreshold == 2)
        #expect(anchor.sampleRate == 48_000 && anchor.channelCount == 2 && anchor.convertedFrameCount == 4)
        #expect(anchor.sampleStride == (interleaved ? 2 : 1))
        #expect(anchor.ptsValue == 48_000 && anchor.ptsTimescale == 48_000 && anchor.nativeSampleCount == 4)
        #expect(anchor.captureRevision == 7 && anchor.callbackSourceIdentity == "synthetic-capture-receipt")
        #expect(anchor.hostBeforeConversion == 123 && anchor.energyAnalysisAvailable)
        #expect(leaf.takeBatch() == nil)
        #expect(channels[0][2 * buffer.stride] == 0.2) // native business PCM is untouched
    }

    @Test
    func numericRingOverflowIsBoundedAndObservable() throws {
        let buffer = try stereoBuffer(interleaved: false, frames: 4)
        let leaf = testLeaf()
        for index in 1...69 {
            leaf.observe(buffer, pts: CMTime(value: Int64(index * 4), timescale: 48_000), nativeSampleCount: 4,
                callbackSourceIdentity: "synthetic-capture-receipt", captureRevision: 1, hostBefore: UInt64(index))
        }
        let batch = try #require(leaf.takeBatch())
        #expect(batch.anchors.count == VerificationPCMLeaf.maximumAnchors)
        #expect(batch.observedBufferCount == 69 && batch.overflowRejectedCount == 5)
        #expect(batch.anchors.first?.sequence == 6 && batch.anchors.last?.sequence == 69)
        #expect(batch.anchors.allSatisfy { $0.lastFrameAboveThreshold == nil && $0.energyAnalysisAvailable })
        #expect(leaf.takeBatch() == nil)
    }

    @Test
    func oversizedOptionalAnalysisRetainsUnavailableNumericObservation() throws {
        let buffer = try stereoBuffer(interleaved: false, frames: VerificationPCMLeaf.maximumAnalyzedFrames + 1)
        let leaf = testLeaf()
        leaf.observe(buffer, pts: CMTime(value: 0, timescale: 48_000), nativeSampleCount: Int(buffer.frameLength),
            callbackSourceIdentity: "synthetic-capture-receipt", captureRevision: 1, hostBefore: 1)
        let anchor = try #require(leaf.takeBatch()?.anchors.first)
        #expect(!anchor.energyAnalysisAvailable && anchor.lastFrameAboveThreshold == nil)
        #expect(anchor.convertedFrameCount == VerificationPCMLeaf.maximumAnalyzedFrames + 1)
        #expect(buffer.frameLength == AVAudioFrameCount(VerificationPCMLeaf.maximumAnalyzedFrames + 1))
    }

    private func testLeaf() -> VerificationPCMLeaf {
        VerificationPCMLeaf(runID: "synthetic-unit-test", timebaseNumerator: 1, timebaseDenominator: 1,
            clockDomain: "unit-test-context")
    }
    private func stereoBuffer(interleaved: Bool, frames: Int) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: 2, interleaved: interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        if interleaved { data[0].update(repeating: 0, count: frames * 2) }
        else { data[0].update(repeating: 0, count: frames); data[1].update(repeating: 0, count: frames) }
        return buffer
    }
}
