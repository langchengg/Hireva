import Foundation

struct RealtimePromptBudgeter {
    struct Profile {
        let cvChunkLimit: Int
        let jdChunkLimit: Int
        let wordsPerChunk: Int
    }

    static func profile(question: String, intent: QuestionIntent, strategy: AnswerStrategy) -> Profile {
        let text = question.lowercased()
        if intent == .companyFit ||
            text.contains("why do you want this role") ||
            text.contains("why this role") ||
            text.contains("why are you interested") {
            return Profile(cvChunkLimit: 1, jdChunkLimit: 1, wordsPerChunk: 120)
        }
        if strategy == .projectWalkthrough || intent == .projectDeepDive {
            return Profile(cvChunkLimit: 2, jdChunkLimit: 1, wordsPerChunk: 120)
        }
        if strategy == .technicalExplanation ||
            text.contains("challenge") ||
            text.contains("difficult") ||
            text.contains("tradeoff") {
            return Profile(cvChunkLimit: 2, jdChunkLimit: 1, wordsPerChunk: 120)
        }
        if text.contains("tell me about yourself") ||
            text.contains("walk me through your resume") ||
            text.contains("introduce yourself") {
            return Profile(cvChunkLimit: 2, jdChunkLimit: 1, wordsPerChunk: 100)
        }
        return Profile(cvChunkLimit: 2, jdChunkLimit: 1, wordsPerChunk: 100)
    }

    static func trim(
        _ context: RetrievedContext,
        question: String,
        intent: QuestionIntent,
        strategy: AnswerStrategy
    ) -> RetrievedContext {
        let selectedProfile = profile(question: question, intent: intent, strategy: strategy)
        return RetrievedContext(
            cvChunks: trim(chunks: context.cvChunks, limit: selectedProfile.cvChunkLimit, wordsPerChunk: selectedProfile.wordsPerChunk),
            jobDescriptionChunks: trim(chunks: context.jobDescriptionChunks, limit: selectedProfile.jdChunkLimit, wordsPerChunk: selectedProfile.wordsPerChunk),
            additionalNotesChunks: []
        )
    }

    static func limitTranscript(_ transcript: String) -> String {
        ContextBudgeter.limitWords(transcript, maxWords: 180)
    }

    private static func trim(chunks: [DocumentChunk], limit: Int, wordsPerChunk: Int) -> [DocumentChunk] {
        Array(chunks.prefix(limit)).map { chunk in
            var trimmed = chunk
            let words = chunk.content.split(whereSeparator: \.isWhitespace)
            if words.count > wordsPerChunk {
                trimmed.content = words.prefix(wordsPerChunk).joined(separator: " ")
                trimmed.wordCount = wordsPerChunk
            } else {
                trimmed.wordCount = words.count
            }
            return trimmed
        }
    }
}
