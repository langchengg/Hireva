import Foundation

struct ExtractedTranscriptQuestion: Equatable {
    var text: String
    var confidence: Double
    var intent: QuestionIntent
    var answerStrategy: AnswerStrategy
}

/// Backwards-compatible facade for system-audio question extraction.
enum SystemAudioQuestionExtractor {
    static func isIncompleteQuestionFragment(_ text: String) -> Bool {
        QuestionCompletenessGate.isIncompleteFragment(text)
    }

    static func canonicalizeQuestionText(_ text: String) -> String {
        QuestionCanonicalizer.canonicalize(text)
    }

    static func duplicateKey(for text: String) -> String {
        SemanticDuplicateKeyBuilder.key(for: text)
    }

    static func extract(from text: String, isFinal: Bool = true) -> [ExtractedTranscriptQuestion] {
        QuestionCandidatePipeline.extract(from: text, isFinal: isFinal).map {
            ExtractedTranscriptQuestion(
                text: $0.text,
                confidence: $0.confidence,
                intent: $0.intent,
                answerStrategy: $0.answerStrategy
            )
        }
    }
}
