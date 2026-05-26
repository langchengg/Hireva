import Foundation

final class SimpleContextRetrievalService: ContextRetrievalService {
    private let documentRepository: DocumentRepository

    init(documentRepository: DocumentRepository) {
        self.documentRepository = documentRepository
    }

    func retrieveContext(
        question: String,
        intent: QuestionIntent,
        maxCVWords: Int = 1_500,
        maxJDWords: Int = 1_000
    ) throws -> RetrievedContext {
        let queryTokens = Set(TextChunker.tokenize(question + " " + intent.rawValue))
        let cv = try rankedChunks(type: .cv, queryTokens: queryTokens)
        let jd = try rankedChunks(type: .jobDescription, queryTokens: queryTokens)

        return RetrievedContext(
            cvChunks: ContextBudgeter.limitChunks(Array(cv.prefix(8)), maxWords: maxCVWords),
            jobDescriptionChunks: ContextBudgeter.limitChunks(Array(jd.prefix(6)), maxWords: maxJDWords)
        )
    }

    private func rankedChunks(type: DocumentType, queryTokens: Set<String>) throws -> [DocumentChunk] {
        let chunks = try documentRepository.chunks(type: type)
        return chunks
            .map { chunk -> (chunk: DocumentChunk, score: Int) in
                let keywordTokens = Set(chunk.keywords)
                let contentTokens = Set(TextChunker.tokenize(chunk.content))
                let keywordScore = keywordTokens.intersection(queryTokens).count * 3
                let contentScore = contentTokens.intersection(queryTokens).count
                let score = keywordScore + contentScore
                return (chunk, score)
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.chunk.chunkIndex < rhs.chunk.chunkIndex
                }
                return lhs.score > rhs.score
            }
            .filter { $0.score > 0 || queryTokens.isEmpty }
            .map(\.chunk)
    }
}
