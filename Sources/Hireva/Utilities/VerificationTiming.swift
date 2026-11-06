import AVFoundation
import CoreMedia
import Darwin
import Foundation
import os

// Opt-in scalar observation only. Production use does not initialize the
// verification configuration, sample clocks, encode records or retain PCM.
enum VerificationTiming {
    static let runID: String? = {
        guard ProcessInfo.processInfo.environment["HIREVA_VERIFICATION_TIMING"] == "1",
              Bundle.main.object(forInfoDictionaryKey: "HirevaVerificationOnly") as? Bool == true,
              let value = HirevaVerificationConfiguration.current,
              value.controlledAudioProcessID != nil,
              value.controlledAudioBundleIdentifier != nil else { return nil }
        return value.runID
    }()
    static var enabled: Bool { runID != nil }
    static let timebase: (numerator: UInt32, denominator: UInt32)? = {
        guard enabled else { return nil }
        var value = mach_timebase_info_data_t()
        guard mach_timebase_info(&value) == KERN_SUCCESS, value.denom != 0 else { return nil }
        return (value.numer, value.denom)
    }()
    static func hostTicks() -> UInt64? {
        guard enabled, timebase != nil else { return nil }
        return mach_absolute_time()
    }
    static func jsonLine<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// IDs are supplied by the operation/card that produced the event. Missing
// versions remain nil: this value never borrows a current AppState snapshot.
struct VerificationTimingEvent: Codable, Sendable {
    let eventType: String
    let runID: String
    let producerHostTicks: UInt64
    let clockDomain: String
    let timebaseNumerator: UInt32
    let timebaseDenominator: UInt32
    let sessionID: String
    var segmentID: String? = nil
    var questionID: String? = nil
    var generationID: String? = nil
    var contextSnapshotID: String? = nil
    var questionRevision: Int? = nil
    var artifactRevision: Int? = nil
    var candidateProfileVersion: Int? = nil
    var opportunityContextVersion: Int? = nil
    var cardID: String? = nil
    var source: String? = nil
    var producerFailure: Bool? = nil

    static func make(_ eventType: String, at tick: UInt64?, sessionID: String,
                     segmentID: String? = nil, questionID: String? = nil,
                     generationID: String? = nil, contextSnapshotID: String? = nil,
                     questionRevision: Int? = nil, artifactRevision: Int? = nil,
                     producerFailure: Bool? = nil) -> Self? {
        guard let runID = VerificationTiming.runID,
              let tick, let timebase = VerificationTiming.timebase else { return nil }
        return Self(eventType: eventType, runID: runID,
                    producerHostTicks: tick, clockDomain: "mach_absolute_time",
                    timebaseNumerator: timebase.numerator, timebaseDenominator: timebase.denominator,
                    sessionID: sessionID, segmentID: segmentID, questionID: questionID,
                    generationID: generationID, contextSnapshotID: contextSnapshotID,
                    questionRevision: questionRevision, artifactRevision: artifactRevision,
                    producerFailure: producerFailure)
    }

    static func card(_ eventType: String, at tick: UInt64?, card: SuggestionCard) -> Self? {
        guard var value = make(eventType, at: tick, sessionID: card.sessionID,
            segmentID: card.transcriptSegmentID, questionID: card.detectedQuestionID ?? card.questionID,
            generationID: card.generationID, contextSnapshotID: card.contextSnapshotID) else { return nil }
        value.cardID = card.id
        value.candidateProfileVersion = card.candidateProfileVersion
        value.opportunityContextVersion = card.opportunityContextVersion
        value.source = card.finalVisibleSource ?? card.sayFirstSource
        return value
    }
}

@MainActor
extension AppState {
    func recordVerificationBoundary(_ eventType: String, at tick: UInt64?, sessionID: String,
        segmentID: String? = nil, questionID: String? = nil, generationID: String? = nil,
        contextSnapshotID: String? = nil, questionRevision: Int? = nil,
        artifactRevision: Int? = nil, producerFailure: Bool? = nil) {
        guard let event = VerificationTimingEvent.make(eventType, at: tick, sessionID: sessionID,
            segmentID: segmentID, questionID: questionID, generationID: generationID,
            contextSnapshotID: contextSnapshotID, questionRevision: questionRevision,
            artifactRevision: artifactRevision, producerFailure: producerFailure) else { return }
        diagnosticsState.recordVerificationTiming(event, mode: settings.effectiveDiagnosticTraceMode)
    }
    func recordVerificationCardPublication(_ card: SuggestionCard, at tick: UInt64?) {
        guard !card.isPartial, let event = VerificationTimingEvent.card(
            "verification.qualified_state_published", at: tick, card: card) else { return }
        diagnosticsState.recordVerificationTiming(event, mode: settings.effectiveDiagnosticTraceMode)
        if card.stageBCompleted == true,
           let full = VerificationTimingEvent.card("verification.full_card_state_published", at: tick, card: card) {
            diagnosticsState.recordVerificationTiming(full, mode: settings.effectiveDiagnosticTraceMode)
        }
    }
}

// The native callback retains only this small scalar ring. Dropped numeric
// observations are counted. The ring owns no stream, Task, delegate or buffer.
final class VerificationPCMLeaf: Sendable {
    struct Anchor: Codable, Sendable {
        let sequence: UInt64
        let callbackSourceIdentity: String
        let captureRevision: UInt64?
        let hostBeforeConversion: UInt64
        let hostAfterAnalysis: UInt64
        let sampledHostClockValue: Int64
        let sampledHostClockTimescale: Int32
        let sampledHostClockSystemUnits: UInt64?
        let ptsValue: Int64
        let ptsTimescale: Int32
        let ptsFlags: UInt32
        let ptsEpoch: Int64
        let nativeSampleCount: Int
        let convertedFrameCount: Int
        let sampleRate: Double
        let channelCount: Int
        let sampleStride: Int
        let energyPowerThreshold: Double
        let lastFrameAboveThreshold: Int?
        let energyAnalysisAvailable: Bool
    }
    struct Batch: Codable, Sendable {
        let eventType: String
        let runID: String
        let clockDomain: String
        let timebaseNumerator: UInt32
        let timebaseDenominator: UInt32
        let observedBufferCount: UInt64
        let overflowRejectedCount: UInt64
        let anchors: [Anchor]
    }
    private struct State: Sendable {
        var sequence: UInt64 = 0
        var overflowRejectedCount: UInt64 = 0
        var anchors: [Anchor] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let runID: String?
    private let timebaseNumerator: UInt32?
    private let timebaseDenominator: UInt32?
    private let clockDomain: String

    // The production leaf receives the already-gated immutable verification
    // values. Unit tests may supply only numeric context to this leaf; no global
    // environment, Bundle, AppState or production preferences are changed.
    init(runID: String? = VerificationTiming.runID,
         timebaseNumerator: UInt32? = VerificationTiming.timebase?.numerator,
         timebaseDenominator: UInt32? = VerificationTiming.timebase?.denominator,
         clockDomain: String = "mach_absolute_time") {
        self.runID = runID
        self.timebaseNumerator = timebaseNumerator
        self.timebaseDenominator = timebaseDenominator
        self.clockDomain = clockDomain
    }
    static let maximumAnchors = 64
    static let maximumAnalyzedFrames = 8_192
    static let energyPowerThreshold: Double = 0.000_004

    // All native objects are synchronously borrowed. No I/O, UI dispatch or
    // provider/DB work occurs here. A large/unsupported buffer stays in the
    // business path; only its optional energy observation becomes unavailable.
    func observe(_ buffer: AVAudioPCMBuffer, pts: CMTime, nativeSampleCount: Int,
                 callbackSourceIdentity: String, captureRevision: UInt64?, hostBefore: UInt64) {
        guard runID != nil, let numerator = timebaseNumerator,
              let denominator = timebaseDenominator, numerator > 0, denominator > 0 else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let stride = buffer.stride
        var lastFrame: Int?
        let available = frames > 0 && frames <= Self.maximumAnalyzedFrames && channels > 0 &&
            channels <= 8 && stride > 0 && buffer.floatChannelData != nil
        if available, let data = buffer.floatChannelData {
            for frame in 0..<frames {
                var power: Double = 0
                for channel in 0..<channels {
                    let sample = Double(data[channel][frame * stride])
                    power += sample * sample
                }
                if power / Double(channels) >= Self.energyPowerThreshold { lastFrame = frame }
            }
        }
        // This bridge converts a known host-clock CMTime. It deliberately
        // does not assume that the arbitrary sample PTS has that clock domain.
        let hostClockTime = CMClockGetTime(CMClockGetHostTimeClock())
        let hostClockUnits: UInt64? = hostClockTime.isValid
            ? CMClockConvertHostTimeToSystemUnits(hostClockTime) : nil
        let hostAfter = mach_absolute_time()
        let sampleRate = buffer.format.sampleRate
        let lastObservedFrame = lastFrame
        state.withLock {
            $0.sequence &+= 1
            let anchor = Anchor(sequence: $0.sequence, callbackSourceIdentity: callbackSourceIdentity,
                captureRevision: captureRevision, hostBeforeConversion: hostBefore,
                hostAfterAnalysis: hostAfter,
                sampledHostClockValue: hostClockTime.value,
                sampledHostClockTimescale: hostClockTime.timescale,
                sampledHostClockSystemUnits: hostClockUnits, ptsValue: pts.value, ptsTimescale: pts.timescale,
                ptsFlags: pts.flags.rawValue, ptsEpoch: pts.epoch, nativeSampleCount: nativeSampleCount,
                convertedFrameCount: frames, sampleRate: sampleRate,
                channelCount: channels, sampleStride: stride,
                energyPowerThreshold: Self.energyPowerThreshold,
                lastFrameAboveThreshold: lastObservedFrame, energyAnalysisAvailable: available)
            if $0.anchors.count == Self.maximumAnchors {
                $0.anchors.removeFirst()
                $0.overflowRejectedCount &+= 1
            }
            $0.anchors.append(anchor)
        }
    }

    // Called by the existing verification poll. It cannot claim a host mapping
    // for arbitrary SCK PTS, a calibrated audio end or a visible SwiftUI frame.
    func takeBatch() -> Batch? {
        guard let runID, let numerator = timebaseNumerator,
              let denominator = timebaseDenominator, numerator > 0, denominator > 0 else { return nil }
        return state.withLock {
            guard !$0.anchors.isEmpty else { return nil }
            let value = Batch(eventType: "verification.pcm.numeric_anchors", runID: runID,
                clockDomain: clockDomain, timebaseNumerator: numerator,
                timebaseDenominator: denominator, observedBufferCount: $0.sequence,
                overflowRejectedCount: $0.overflowRejectedCount, anchors: $0.anchors)
            $0.anchors.removeAll(keepingCapacity: true)
            return value
        }
    }
}
