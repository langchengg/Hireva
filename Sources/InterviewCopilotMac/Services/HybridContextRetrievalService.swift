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
        let settings = settingsProvider()
        let provider = embeddingProviderResolver()

        let emptyQueryFallbackUsed = question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let queryTokens = Set(TextChunker.tokenize(question + " " + intent.rawValue))

        let allCVChunks = try documentRepository.chunks(type: .cv)
        let allJDChunks = try documentRepository.chunks(type: .jobDescription)
        let allNotesChunks = try documentRepository.chunks(type: .additionalNotes)

        // Pre-telemetry variables
        var queryEmbeddingGenerated = false
        var queryEmbeddingLatencyMS: Double? = nil
        var vectorSearchLatencyMS: Double? = nil
        var embeddingWarnings: [String] = []
        var fallbackReason: String? = nil
        var activeMode = "hybrid"

        // Determine Retrieval Profile
        let profile = RetrievalProfile.from(intent, strategy ?? .directAnswer, question)
        var actualCVWords = maxCVWords
        var actualJDWords = maxJDWords
        var cvChunksLimit: Int? = nil

        switch profile {
        case .whyRole:
            actualCVWords = min(maxCVWords, 240)
            actualJDWords = min(maxJDWords, 180)
            cvChunksLimit = 1
        case .projectWalkthrough:
            actualCVWords = min(maxCVWords, 300)
            actualJDWords = min(maxJDWords, 120)
        case .technicalChallenge:
            actualCVWords = min(maxCVWords, 300)
            actualJDWords = min(maxJDWords, 120)
        case .tellMeAboutYourself:
            actualCVWords = min(maxCVWords, 240)
            actualJDWords = min(maxJDWords, 120)
        case .generic:
            actualCVWords = maxCVWords
            actualJDWords = maxJDWords
        }

        // Rule 1: Is Vector RAG enabled?
        if !settings.enableVectorRAG {
            activeMode = "keywordOnly"
            fallbackReason = "Vector RAG Disabled"
        }

        // Rule 2: Provider availability. Missing cloud embeddings should never
        // block retrieval; keyword RAG remains ready.
        if activeMode == "hybrid" && provider == nil {
            activeMode = "keywordOnly"
            fallbackReason = "Embedding provider not configured"
        }

        // Rule 3: Coverage Check (>= 80% coverage required)
        var coveragePercent: Double = 100.0
        if activeMode == "hybrid", let provider {
            do {
                let cov = try documentRepository.embeddingCoverage(
                    currentProvider: provider.providerID,
                    currentModel: settings.embeddingModelName
                )
                coveragePercent = cov.coveragePercent
                if coveragePercent < 80.0 && !settings.forceHybridRAG {
                    activeMode = "keywordOnly"
                    fallbackReason = "Low Coverage (\(Int(coveragePercent))%)"
                }
            } catch {
                embeddingWarnings.append("Coverage check failed: \(error.localizedDescription)")
            }
        }

        // Embed the query
        var queryEmbedding: [Float]? = nil
        if activeMode == "hybrid", let provider = provider {
            let embedStart = Date()
            do {
                queryEmbedding = try await Self.withTimeout(seconds: 0.45) {
                    try await provider.embed(text: question)
                }
                queryEmbeddingGenerated = true
                queryEmbeddingLatencyMS = Date().timeIntervalSince(embedStart) * 1000.0
            } catch {
                activeMode = "keywordOnly"
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
                var keywordScore: Double
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
                var kwScore = Double(keyOverlap * 3 + contentOverlap)

                // Apply Profile-Specific Keyword Boosting
                if chunk.documentType == .cv {
                    let contentLower = chunk.content.lowercased()
                    switch profile {
                    case .whyRole:
                        if HybridContextRetrievalService.isFormattingChunk(chunk.content) {
                            kwScore -= 9999.0 // strongly penalize formatting chunks
                        }
                    case .projectWalkthrough:
                        if contentLower.contains("project") || contentLower.contains("grasping") || contentLower.contains("thesis") || contentLower.contains("robotics") || contentLower.contains("vlm") || contentLower.contains("ros2") {
                            kwScore += 10.0
                        }
                    case .technicalChallenge:
                        if contentLower.contains("challenge") || contentLower.contains("difficult") || contentLower.contains("solved") || contentLower.contains("implemented") || contentLower.contains("optimized") || contentLower.contains("critical") {
                            kwScore += 10.0
                        }
                    case .tellMeAboutYourself:
                        if contentLower.contains("education") || contentLower.contains("degree") || contentLower.contains("university") || contentLower.contains("project") || contentLower.contains("experience") {
                            kwScore += 10.0
                        }
                    case .generic:
                        break
                    }
                }

                return InterimScored(chunk: chunk, keywordScore: kwScore, keyOverlap: keyOverlap, contentOverlap: contentOverlap)
            }

            // B: Compute Semantic Cosine score if in hybrid mode
            if activeMode == "hybrid", let qEmb = queryEmbedding {
                let vectorStart = Date()
                for i in 0..<scored.count {
                    let chunk = scored[i].chunk
                    // Skip semantic search for heavily penalized formatting chunks
                    if profile == .whyRole && HybridContextRetrievalService.isFormattingChunk(chunk.content) {
                        scored[i].semanticScore = 0.0
                        continue
                    }
                    if let chunkData = chunk.embedding {
                        let chunkEmb = VectorStore.decodeEmbedding(chunkData)
                        if chunkEmb.count == qEmb.count {
                            let sim = VectorStore.cosineSimilarity(qEmb, chunkEmb)
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
        let (rankedNotes, notesZeroFallback) = rankAndScore(chunks: allNotesChunks)

        let zeroScoreFallbackUsed = !emptyQueryFallbackUsed && 
            ((!allCVChunks.isEmpty && cvZeroFallback) || (!allJDChunks.isEmpty && jdZeroFallback) || (!allNotesChunks.isEmpty && notesZeroFallback))

        let candidateCV = Array(rankedCV.prefix(8))
        let candidateJD = Array(rankedJD.prefix(6))
        let candidateNotes = Array(rankedNotes.prefix(4))

        func applyBudget(candidates: [RetrievedChunk], maxWords: Int, maxChunks: Int? = nil) -> (included: [RetrievedChunk], excluded: [RetrievedChunk], wordsUsed: Int, updatedCandidates: [RetrievedChunk]) {
            var remaining = maxWords
            var included: [RetrievedChunk] = []
            var excluded: [RetrievedChunk] = []
            var wordsUsed = 0
            var updatedCandidates: [RetrievedChunk] = []
            var chunksCount = 0

            for candidate in candidates {
                var chunk = candidate
                let withinLimit = (maxChunks == nil || chunksCount < maxChunks!)
                if remaining > 0 && withinLimit {
                    let words = chunk.fullContent.split(whereSeparator: \.isWhitespace)
                    if words.count <= remaining {
                        chunk.isIncludedInPrompt = true
                        included.append(chunk)
                        wordsUsed += words.count
                        remaining -= words.count
                        chunksCount += 1
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
                        chunksCount += 1
                    }
                } else {
                    chunk.isIncludedInPrompt = false
                    excluded.append(chunk)
                }
                updatedCandidates.append(chunk)
            }

            return (included, excluded, wordsUsed, updatedCandidates)
        }

        let (includedCV, excludedCV, cvWordsUsed, updatedCV) = applyBudget(candidates: candidateCV, maxWords: actualCVWords, maxChunks: cvChunksLimit)
        let (includedJD, excludedJD, jdWordsUsed, updatedJD) = applyBudget(candidates: candidateJD, maxWords: actualJDWords)
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
            cvWordBudget: actualCVWords,
            jdWordBudget: actualJDWords,
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

// MARK: - RetrievalProfile Enum and Helpers
enum RetrievalProfile: String, Codable {
    case whyRole
    case projectWalkthrough
    case technicalChallenge
    case tellMeAboutYourself
    case generic

    static func from(_ intent: QuestionIntent, _ strategy: AnswerStrategy, _ questionText: String) -> RetrievalProfile {
        let textLower = questionText.lowercased()
        if textLower.contains("why do you want this role") || 
           textLower.contains("why this role") || 
           textLower.contains("why do you want to work") || 
           textLower.contains("why are you interested in this") ||
           intent == .companyFit {
            return .whyRole
        }
        
        switch strategy {
        case .projectWalkthrough:
            return .projectWalkthrough
        case .technicalExplanation:
            return .technicalChallenge
        case .directAnswer where intent == .projectDeepDive:
            return .projectWalkthrough
        case .starStory:
            if textLower.contains("tell me about a time") || textLower.contains("challenge") || textLower.contains("difficult") {
                return .technicalChallenge
            }
            return .generic
        default:
            if textLower.contains("tell me about yourself") || textLower.contains("walk me through your resume") || textLower.contains("introduce yourself") {
                return .tellMeAboutYourself
            }
            return .generic
        }
    }
}

extension HybridContextRetrievalService {
    static func isFormattingChunk(_ content: String) -> Bool {
        let lower = content.lowercased()
        if lower.contains("documentclass") || lower.contains("usepackage") || lower.contains("geometry") || lower.contains("hidelinks") {
            return true
        }
        // If it looks like a contact details block with very little content
        if (lower.contains("email") || lower.contains("@")) && (lower.contains("linkedin.com") || lower.contains("github.com") || lower.contains("phone")) {
            return true
        }
        return false
    }

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(
                    domain: "EmbeddingTimeout",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Query embedding timed out after \(Int(seconds * 1000)) ms"]
                )
            }
            guard let result = try await group.next() else {
                throw NSError(domain: "EmbeddingTimeout", code: 2)
            }
            group.cancelAll()
            return result
        }
    }
}
