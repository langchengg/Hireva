import Foundation

/// Session-scoped reconciler for cumulative ASR callbacks.
///
/// Apple Speech can emit the same cumulative text many times, including after a
/// recognition task restart. Question extraction must see only the novel span of
/// that callback; the full cumulative transcript remains available for UI,
/// persistence, and diagnostics.
struct TranscriptReconciler {
    private var previousCumulativeTextByStream = [String: String]()

    mutating func reset() {
        previousCumulativeTextByStream.removeAll()
    }

    mutating func segmentForQuestionExtraction(_ segment: TranscriptSegment) -> TranscriptSegment? {
        guard shouldReconcile(segment) else {
            return segment
        }

        let key = streamKey(for: segment)
        let current = QuestionTextUtilities.collapse(segment.text)
        guard !current.isEmpty else {
            previousCumulativeTextByStream[key] = current
            return nil
        }

        defer {
            previousCumulativeTextByStream[key] = current
        }

        guard let previous = previousCumulativeTextByStream[key], !previous.isEmpty else {
            return segmentWithText(current, from: segment, sourceStartOffsetUTF16: 0)
        }

        let novelStartUTF16 = novelSuffixStartUTF16(previous: previous, current: current)
        guard novelStartUTF16 < (current as NSString).length else {
            return nil
        }

        let novelText = substring(current, fromUTF16Offset: novelStartUTF16)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !novelText.isEmpty else {
            return nil
        }

        let trimmedStartOffset = leadingTrimmedUTF16Offset(in: substring(current, fromUTF16Offset: novelStartUTF16))
        return segmentWithText(
            novelText,
            from: segment,
            sourceStartOffsetUTF16: novelStartUTF16 + trimmedStartOffset
        )
    }

    private func shouldReconcile(_ segment: TranscriptSegment) -> Bool {
        switch segment.source {
        case .systemAudio, .processAudio, .mock:
            return segment.recognitionTaskID != nil ||
                segment.sourceTextStartUTF16 != nil ||
                segment.sourceTextEndUTF16 != nil
        case .microphone, .mixed:
            return false
        }
    }

    private func streamKey(for segment: TranscriptSegment) -> String {
        "\(segment.sessionID)|\(segment.source.rawValue)|\(segment.speaker.rawValue)"
    }

    private func novelSuffixStartUTF16(previous: String, current: String) -> Int {
        let previousLength = (previous as NSString).length
        let currentLength = (current as NSString).length
        let sharedLimit = min(previousLength, currentLength)
        var shared = 0

        while shared < sharedLimit {
            let previousUnit = (previous as NSString).character(at: shared)
            let currentUnit = (current as NSString).character(at: shared)
            if previousUnit != currentUnit { break }
            shared += 1
        }

        if shared == 0 {
            return 0
        }

        // Avoid beginning a novel span in the middle of a word after a minor
        // ASR correction. Fall back to the previous whitespace boundary.
        if shared < currentLength,
           shared > 0,
           isWordScalar(current, atUTF16Offset: shared - 1),
           isWordScalar(current, atUTF16Offset: shared) {
            return lastWhitespaceBoundaryUTF16(in: current, before: shared)
        }

        return shared
    }

    private func segmentWithText(
        _ text: String,
        from segment: TranscriptSegment,
        sourceStartOffsetUTF16: Int
    ) -> TranscriptSegment {
        let baseStart = segment.sourceTextStartUTF16 ?? 0
        let sourceStart = baseStart + sourceStartOffsetUTF16
        return TranscriptSegment(
            id: segment.id,
            sessionID: segment.sessionID,
            source: segment.source,
            speaker: segment.speaker,
            text: text,
            startTime: segment.startTime,
            endTime: segment.endTime,
            createdAt: segment.createdAt,
            inputDeviceName: segment.inputDeviceName,
            outputDeviceName: segment.outputDeviceName,
            deviceID: segment.deviceID,
            confidence: segment.confidence,
            asrFirstPartialMS: segment.asrFirstPartialMS,
            asrFinalMS: segment.asrFinalMS,
            asrBestSelectedMS: segment.asrBestSelectedMS,
            asrFinalizationReason: segment.asrFinalizationReason,
            recognitionTaskID: segment.recognitionTaskID,
            recognitionEventSequence: segment.recognitionEventSequence,
            sourceTextStartUTF16: sourceStart,
            sourceTextEndUTF16: sourceStart + (text as NSString).length,
            recognitionIsFinal: segment.recognitionIsFinal
        )
    }

    private func substring(_ text: String, fromUTF16Offset offset: Int) -> String {
        let boundedOffset = min(max(offset, 0), (text as NSString).length)
        let index = String.Index(utf16Offset: boundedOffset, in: text)
        return String(text[index...])
    }

    private func leadingTrimmedUTF16Offset(in text: String) -> Int {
        let trimmed = text.drop(while: { $0.isWhitespace || $0.isNewline })
        guard let first = trimmed.first, let index = text.firstIndex(of: first) else {
            return (text as NSString).length
        }
        return index.utf16Offset(in: text)
    }

    private func isWordScalar(_ text: String, atUTF16Offset offset: Int) -> Bool {
        guard offset >= 0, offset < (text as NSString).length else { return false }
        let index = String.Index(utf16Offset: offset, in: text)
        return text[index].isLetter || text[index].isNumber
    }

    private func lastWhitespaceBoundaryUTF16(in text: String, before offset: Int) -> Int {
        guard offset > 0 else { return 0 }
        var candidate = offset
        while candidate > 0 {
            let index = String.Index(utf16Offset: candidate - 1, in: text)
            if text[index].isWhitespace || text[index].isNewline {
                return candidate
            }
            candidate -= 1
        }
        return 0
    }
}
