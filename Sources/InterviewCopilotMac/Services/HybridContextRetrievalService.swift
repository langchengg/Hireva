import Foundation

final class HybridContextRetrievalService: ContextRetrievalService {
    private let documentRepository: DocumentRepository
    private let settingsProvider: () -> AppSettings
    private let embeddingProviderResolver: () -> EmbeddingProvider?

    init(
        documentRepository: DocumentRepository,
        settingsProvider: @escaping () -> AppSettings,
        embeddingProviderResolver: @escaping () -> EmbeddingProvider?
    ) {
        self.documentRepository = documentRepository
        self.settingsProvider = settingsProvider
        self.embeddingProviderResolver = embeddingProviderResolver
    }

    func retrieveContext(
        question: String,
        intent: QuestionIntent,
        maxCVWords: Int = 1_500,
        maxJDWords: Int = 1_000
    ) async throws -> RetrievedContext {
        try await retrieveContextWithTrace(question: question, intent: intent, maxCVWords: maxCVWords, maxJDWords: maxJDWords).context
    }

    func retrieveContextWithTrace(
        question: String,
        intent: QuestionIntent,
        maxCVWords: Int = 1_500,
        maxJDWords: Int = 1_000
    ) async throws -> (context: RetrievedContext, trace: RetrievalTrace) {
        let startTime = Date()
        let settings = settingsProvider()
        let provider = embeddingProviderResolver()

        let emptyQueryFallbackUsed = question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let queryTokens = Set(TextChunker.tokenize(question + " " + intent.rawValue))

        let allCVChunks = try documentRepository.chunks(type: .cv)
        let allJDChunks = try documentRepository.chunks(type: .jobDescription)

        // Pre-telemetry variables
        var queryEmbeddingGenerated = false
        var queryEmbeddingLatencyMS: Double? = nil
        var vectorSearchLatencyMS: Double? = nil
        var embeddingWarnings: [String] = []
        var fallbackReason: String? = nil
        var activeMode = "hybrid"

        // Rule 1: Is Vector RAG enabled?
        if !settings.enableVectorRAG {
            activeMode = "keywordOnly"
            fallbackReason = "Vector RAG Disabled"
        }

        // Rule 2: Coverage Check (>= 80% coverage required)
        var coveragePercent: Double = 100.0
        if activeMode == "hybrid" {
            do {
                let cov = try documentRepository.embeddingCoverage(
                    currentProvider: provider?.providerID ?? settings.embeddingProviderKind.rawValue,
                    currentModel: settings.embeddingModelName
                )
                coveragePercent = cov.coveragePercent
                if coveragePercent < 80.0 && !settings.forceHybridRAG {
                    activeMode = "vectorFallback"
                    fallbackReason = "Low Coverage (\(Int(coveragePercent))%)"
                }
            } catch {
                embeddingWarnings.append("Coverage check failed: \(error.localizedDescription)")
            }
        }

        // Rule 3: Provider availability
        if activeMode == "hybrid" && provider == nil {
            activeMode = "vectorFallback"
            fallbackReason = "No Provider Available"
        }

        // Embed the query
        var queryEmbedding: [Float]? = nil
        if activeMode == "hybrid", let provider = provider {
            let embedStart = Date()
            do {
                queryEmbedding = try await provider.embed(text: question)
                queryEmbeddingGenerated = true
                queryEmbeddingLatencyMS = Date().timeIntervalSince(embedStart) * 1000.0
            } catch {
                activeMode = "vectorFallback"
                fallbackReason = "Query Embed Failed: \(error.localizedDescription)"
                embeddingWarnings.append("Failed to embed query: \(error.localizedDescription)")
            }
        }

        // Execute Hybrid Scoring or Keyword scoring depending on the mode
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
                        wordCount: chunk.wordCount,
                        semanticScore: 0.0,
                        keywordScoreNormalized: 0.0,
                        finalHybridScore: 0.0,
                        retrievalMode: activeMode
                    )
                }
                return (ranked, false)
            }

            // A: Compute Keyword score
            struct InterimScored {
                let chunk: DocumentChunk
                let keywordScore: Double
                let keyOverlap: Int
                let contentOverlap: Int
                var semanticScore: Double?
                var keywordScoreNormalized: Double?
                var finalHybridScore: Double?
            }

            var scored = chunks.map { chunk -> InterimScored in
                let keywordTokens = Set(chunk.keywords)
                let contentTokens = Set(TextChunker.tokenize(chunk.content))
                let keyOverlap = keywordTokens.intersection(queryTokens).count
                let contentOverlap = contentTokens.intersection(queryTokens).count
                let kwScore = Double(keyOverlap * 3 + contentOverlap)
                return InterimScored(chunk: chunk, keywordScore: kwScore, keyOverlap: keyOverlap, contentOverlap: contentOverlap)
            }

            // B: Compute Semantic Cosine score if in hybrid mode
            if activeMode == "hybrid", let qEmb = queryEmbedding {
                let vectorStart = Date()
                for i in 0..<scored.count {
                    let chunk = scored[i].chunk
                    if let chunkData = chunk.embedding {
                        let chunkEmb = VectorStore.decodeEmbedding(chunkData)
                        if chunkEmb.count == qEmb.count {
                            let sim = VectorStore.cosineSimilarity(qEmb, chunkEmb)
                            // Cosine similarity naturally ranges from -1 to 1; map or clip negative to 0.0
                            scored[i].semanticScore = max(0.0, sim)
                        } else {
                            embeddingWarnings.append("Dimension mismatch on chunk \(chunk.id): expected \(qEmb.count) but got \(chunkEmb.count)")
                        }
                    }
                }
                vectorSearchLatencyMS = (vectorSearchLatencyMS ?? 0.0) + Date().timeIntervalSince(vectorStart) * 1000.0
            }

            // C: Normalize scores and compute hybrid scores
            let maxKeyword = scored.map(\.keywordScore).max() ?? 0.0
            let maxSemantic = scored.compactMap(\.semanticScore).max() ?? 0.0

            for i in 0..<scored.count {
                let normKw = maxKeyword > 0.0 ? (scored[i].keywordScore / maxKeyword) : 0.0
                scored[i].keywordScoreNormalized = normKw

                if activeMode == "hybrid" {
                    let normSem = maxSemantic > 0.0 ? ((scored[i].semanticScore ?? 0.0) / maxSemantic) : 0.0
                    let hybridVal = settings.hybridSemanticWeight * normSem + settings.hybridKeywordWeight * normKw
                    scored[i].finalHybridScore = hybridVal
                } else {
                    scored[i].finalHybridScore = normKw
                }
            }

            // D: Determine fallbacks and rank
            let sortingScoreSelector: (InterimScored) -> Double = { item in
                if activeMode == "hybrid" {
                    return item.finalHybridScore ?? item.keywordScoreNormalized ?? 0.0
                } else {
                    return item.keywordScore
                }
            }

            let allZeroScores = scored.allSatisfy { sortingScoreSelector($0) == 0.0 }

            if allZeroScores {
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
                            wordCount: item.chunk.wordCount,
                            semanticScore: item.semanticScore,
                            keywordScoreNormalized: item.keywordScoreNormalized,
                            finalHybridScore: 0.0,
                            retrievalMode: activeMode
                        )
                    }
                return (ranked, true)
            } else {
                let sorted = scored.sorted { lhs, rhs in
                    let scoreL = sortingScoreSelector(lhs)
                    let scoreR = sortingScoreSelector(rhs)
                    if scoreL == scoreR {
                        return lhs.chunk.chunkIndex < rhs.chunk.chunkIndex
                    }
                    return scoreL > scoreR
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
                        score: sortingScoreSelector(item),
                        keywordOverlapCount: item.keyOverlap,
                        contentOverlapCount: item.contentOverlap,
                        rank: index + 1,
                        isIncludedInPrompt: false,
                        sectionTitle: item.chunk.sectionTitle,
                        wordCount: item.chunk.wordCount,
                        semanticScore: item.semanticScore,
                        keywordScoreNormalized: item.keywordScoreNormalized,
                        finalHybridScore: item.finalHybridScore,
                        retrievalMode: activeMode
                    )
                }
                return (ranked, false)
            }
        }

        let (rankedCV, cvZeroFallback) = rankAndScore(chunks: allCVChunks)
        let (rankedJD, jdZeroFallback) = rankAndScore(chunks: allJDChunks)

        let zeroScoreFallbackUsed = !emptyQueryFallbackUsed && 
            ((!allCVChunks.isEmpty && cvZeroFallback) || (!allJDChunks.isEmpty && jdZeroFallback))

        let candidateCV = Array(rankedCV.prefix(8))
        let candidateJD = Array(rankedJD.prefix(6))

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
                            wordCount: remaining,
                            semanticScore: chunk.semanticScore,
                            keywordScoreNormalized: chunk.keywordScoreNormalized,
                            finalHybridScore: chunk.finalHybridScore,
                            retrievalMode: chunk.retrievalMode
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
            zeroScoreFallbackUsed: zeroScoreFallbackUsed,
            
            // Vector Telemetry
            retrievalMode: activeMode,
            embeddingProvider: provider?.providerID ?? settings.embeddingProviderKind.rawValue,
            embeddingModel: settings.embeddingModelName,
            embeddingCoveragePercent: coveragePercent,
            queryEmbeddingGenerated: queryEmbeddingGenerated,
            queryEmbeddingLatencyMS: queryEmbeddingLatencyMS,
            vectorSearchLatencyMS: vectorSearchLatencyMS,
            hybridSemanticWeight: settings.hybridSemanticWeight,
            hybridKeywordWeight: settings.hybridKeywordWeight,
            embeddingWarnings: embeddingWarnings,
            fallbackReason: fallbackReason
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
            }
        )

        return (context, trace)
    }
}
