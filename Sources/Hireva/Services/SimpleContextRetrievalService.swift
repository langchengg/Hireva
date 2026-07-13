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
    ) async throws -> RetrievedContext {
        try await retrieveContextWithTrace(question: question, intent: intent, maxCVWords: maxCVWords, maxJDWords: maxJDWords, strategy: nil).context
    }

    func retrieveContextWithTrace(
        question: String,
        intent: QuestionIntent,
        maxCVWords: Int = 1_500,
        maxJDWords: Int = 1_000
    ) async throws -> (context: RetrievedContext, trace: RetrievalTrace) {
        try await retrieveContextWithTrace(question: question, intent: intent, maxCVWords: maxCVWords, maxJDWords: maxJDWords, strategy: nil)
    }

    func retrieveContextWithTrace(
        question: String,
        intent: QuestionIntent,
        maxCVWords: Int = 1_500,
        maxJDWords: Int = 1_000,
        strategy: AnswerStrategy?
    ) async throws -> (context: RetrievedContext, trace: RetrievalTrace) {
        let startTime = Date()

        let emptyQueryFallbackUsed = question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let queryTokens = Set(TextChunker.tokenize(question + " " + intent.rawValue))

        let allCVChunks = try documentRepository.chunks(type: .cv)
        let allJDChunks = try documentRepository.chunks(type: .jobDescription)
        let allNotesChunks = try documentRepository.chunks(type: .additionalNotes)

        func rankAndScore(chunks: [DocumentChunk]) -> (ranked: [RetrievedChunk], zeroScoreFallback: Bool) {
            if emptyQueryFallbackUsed {
                let ranked = chunks.enumerated().map { (index, chunk) in
                    RetrievedChunk(
                        id: chunk.id,
                        documentID: chunk.documentID,
                        documentType: chunk.documentType,
                        chunkIndex: chunk.chunkIndex,
                        contentPreview: String(chunk.content.prefix(80)),
                        fullContent: chunk.content,
                        keywords: chunk.keywords,
                        score: 0.0,
                        keywordOverlapCount: 0,
                        contentOverlapCount: 0,
                        rank: index + 1,
                        isIncludedInPrompt: false,
                        sectionTitle: chunk.sectionTitle,
                        wordCount: chunk.wordCount
                    )
                }
                return (ranked, false)
            }

            var scored = chunks.map { chunk -> (chunk: DocumentChunk, score: Double, keyOverlap: Int, contentOverlap: Int) in
                let keywordTokens = Set(chunk.keywords)
                let contentTokens = Set(TextChunker.tokenize(chunk.content))
                let keyOverlap = keywordTokens.intersection(queryTokens).count
                let contentOverlap = contentTokens.intersection(queryTokens).count
                let score = Double(keyOverlap * 3 + contentOverlap)
                return (chunk, score, keyOverlap, contentOverlap)
            }

            let allZero = scored.allSatisfy { $0.score == 0 }

            if allZero {
                let ranked = scored.sorted { $0.chunk.chunkIndex < $1.chunk.chunkIndex }
                    .enumerated().map { (index, item) in
                        RetrievedChunk(
                            id: item.chunk.id,
                            documentID: item.chunk.documentID,
                            documentType: item.chunk.documentType,
                            chunkIndex: item.chunk.chunkIndex,
                            contentPreview: String(item.chunk.content.prefix(80)),
                            fullContent: item.chunk.content,
                            keywords: item.chunk.keywords,
                            score: 0.0,
                            keywordOverlapCount: 0,
                            contentOverlapCount: 0,
                            rank: index + 1,
                            isIncludedInPrompt: false,
                            sectionTitle: item.chunk.sectionTitle,
                            wordCount: item.chunk.wordCount
                        )
                    }
                return (ranked, true)
            } else {
                let nonZero = scored.filter { $0.score > 0 }
                let sorted = nonZero.sorted { lhs, rhs in
                    if lhs.score == rhs.score {
                        return lhs.chunk.chunkIndex < rhs.chunk.chunkIndex
                    }
                    return lhs.score > rhs.score
                }

                let ranked = sorted.enumerated().map { (index, item) in
                    RetrievedChunk(
                        id: item.chunk.id,
                        documentID: item.chunk.documentID,
                        documentType: item.chunk.documentType,
                        chunkIndex: item.chunk.chunkIndex,
                        contentPreview: String(item.chunk.content.prefix(80)),
                        fullContent: item.chunk.content,
                        keywords: item.chunk.keywords,
                        score: item.score,
                        keywordOverlapCount: item.keyOverlap,
                        contentOverlapCount: item.contentOverlap,
                        rank: index + 1,
                        isIncludedInPrompt: false,
                        sectionTitle: item.chunk.sectionTitle,
                        wordCount: item.chunk.wordCount
                    )
                }
                return (ranked, false)
            }
        }

        let (rankedCV, cvZeroFallback) = rankAndScore(chunks: allCVChunks)
        let (rankedJD, jdZeroFallback) = rankAndScore(chunks: allJDChunks)
        let (rankedNotes, notesZeroFallback) = rankAndScore(chunks: allNotesChunks)

        // Trigger zeroScoreFallback if either CV or JD has chunks but they all scored 0
        let zeroScoreFallbackUsed = !emptyQueryFallbackUsed && 
            ((!allCVChunks.isEmpty && cvZeroFallback) || (!allJDChunks.isEmpty && jdZeroFallback) || (!allNotesChunks.isEmpty && notesZeroFallback))

        let candidateCV = Array(rankedCV.prefix(8))
        let candidateJD = Array(rankedJD.prefix(6))
        let candidateNotes = Array(rankedNotes.prefix(4))

        func applyBudget(candidates: [RetrievedChunk], maxWords: Int) -> (included: [RetrievedChunk], excluded: [RetrievedChunk], wordsUsed: Int, updatedCandidates: [RetrievedChunk]) {
            var remaining = maxWords
            var included: [RetrievedChunk] = []
            var excluded: [RetrievedChunk] = []
            var wordsUsed = 0
            var updatedCandidates: [RetrievedChunk] = []

            for candidate in candidates {
                var chunk = candidate
                if remaining > 0 {
                    let words = chunk.fullContent.split(whereSeparator: \.isWhitespace)
                    if words.count <= remaining {
                        chunk.isIncludedInPrompt = true
                        included.append(chunk)
                        wordsUsed += words.count
                        remaining -= words.count
                    } else {
                        chunk.isIncludedInPrompt = true
                        let trimmedWords = words.prefix(remaining)
                        let trimmedContent = trimmedWords.joined(separator: " ")
                        let trimmedChunk = RetrievedChunk(
                            id: chunk.id,
                            documentID: chunk.documentID,
                            documentType: chunk.documentType,
                            chunkIndex: chunk.chunkIndex,
                            contentPreview: String(trimmedContent.prefix(80)),
                            fullContent: trimmedContent,
                            keywords: chunk.keywords,
                            score: chunk.score,
                            keywordOverlapCount: chunk.keywordOverlapCount,
                            contentOverlapCount: chunk.contentOverlapCount,
                            rank: chunk.rank,
                            isIncludedInPrompt: true,
                            sectionTitle: chunk.sectionTitle,
                            wordCount: remaining
                        )
                        included.append(trimmedChunk)
                        wordsUsed += remaining
                        remaining = 0
                        chunk = trimmedChunk
                    }
                } else {
                    chunk.isIncludedInPrompt = false
                    excluded.append(chunk)
                }
                updatedCandidates.append(chunk)
            }

            return (included, excluded, wordsUsed, updatedCandidates)
        }

        let (includedCV, excludedCV, cvWordsUsed, updatedCV) = applyBudget(candidates: candidateCV, maxWords: maxCVWords)
        let (includedJD, excludedJD, jdWordsUsed, updatedJD) = applyBudget(candidates: candidateJD, maxWords: maxJDWords)
        let (includedNotes, _, _, _) = applyBudget(candidates: candidateNotes, maxWords: 500)

        var finalRankedCV = updatedCV
        if rankedCV.count > candidateCV.count {
            for i in candidateCV.count..<rankedCV.count {
                var chunk = rankedCV[i]
                chunk.isIncludedInPrompt = false
                finalRankedCV.append(chunk)
            }
        }

        var finalRankedJD = updatedJD
        if rankedJD.count > candidateJD.count {
            for i in candidateJD.count..<rankedJD.count {
                var chunk = rankedJD[i]
                chunk.isIncludedInPrompt = false
                finalRankedJD.append(chunk)
            }
        }

        var finalExcludedCV = excludedCV
        if rankedCV.count > candidateCV.count {
            for i in candidateCV.count..<rankedCV.count {
                var chunk = rankedCV[i]
                chunk.isIncludedInPrompt = false
                finalExcludedCV.append(chunk)
            }
        }

        var finalExcludedJD = excludedJD
        if rankedJD.count > candidateJD.count {
            for i in candidateJD.count..<rankedJD.count {
                var chunk = rankedJD[i]
                chunk.isIncludedInPrompt = false
                finalExcludedJD.append(chunk)
            }
        }

        let latencyMS = Date().timeIntervalSince(startTime) * 1000.0

        let trace = RetrievalTrace(
            id: UUID(),
            query: question,
            intent: intent.rawValue,
            createdAt: Date(),
            rankedCVChunks: finalRankedCV,
            rankedJDChunks: finalRankedJD,
            includedCVChunks: includedCV,
            includedJDChunks: includedJD,
            excludedCVChunks: finalExcludedCV,
            excludedJDChunks: finalExcludedJD,
            cvWordsUsed: cvWordsUsed,
            jdWordsUsed: jdWordsUsed,
            cvWordBudget: maxCVWords,
            jdWordBudget: maxJDWords,
            retrievalLatencyMS: latencyMS,
            emptyQueryFallbackUsed: emptyQueryFallbackUsed,
            zeroScoreFallbackUsed: zeroScoreFallbackUsed
        )

        let context = RetrievedContext(
            cvChunks: includedCV.map { chunk in
                DocumentChunk(
                    id: chunk.id,
                    documentID: chunk.documentID,
                    documentType: chunk.documentType,
                    chunkIndex: chunk.chunkIndex,
                    content: chunk.fullContent,
                    keywords: chunk.keywords,
                    sectionTitle: chunk.sectionTitle,
                    wordCount: chunk.wordCount,
                    metadataJSON: nil,
                    createdAt: Date()
                )
            },
            jobDescriptionChunks: includedJD.map { chunk in
                DocumentChunk(
                    id: chunk.id,
                    documentID: chunk.documentID,
                    documentType: chunk.documentType,
                    chunkIndex: chunk.chunkIndex,
                    content: chunk.fullContent,
                    keywords: chunk.keywords,
                    sectionTitle: chunk.sectionTitle,
                    wordCount: chunk.wordCount,
                    metadataJSON: nil,
                    createdAt: Date()
                )
            },
            additionalNotesChunks: includedNotes.map { chunk in
                DocumentChunk(
                    id: chunk.id,
                    documentID: chunk.documentID,
                    documentType: chunk.documentType,
                    chunkIndex: chunk.chunkIndex,
                    content: chunk.fullContent,
                    keywords: chunk.keywords,
                    sectionTitle: chunk.sectionTitle,
                    wordCount: chunk.wordCount,
                    metadataJSON: nil,
                    createdAt: Date()
                )
            }
        )

        return (context, trace)
    }
}
