import Foundation

struct RetrievedChunk: Codable, Identifiable, Equatable, Hashable {
    let id: String                  // document_chunks.id
    let documentID: String
    let documentType: DocumentType
    let chunkIndex: Int
    let contentPreview: String      // first ~80 chars
    let fullContent: String
    let keywords: [String]
    var score: Double               // keywordScore + contentScore or finalHybridScore
    let keywordOverlapCount: Int
    let contentOverlapCount: Int
    let rank: Int                   // 1-based position after sorting
    var isIncludedInPrompt: Bool    // Track if actually sent to LLM
    var sectionTitle: String?       // From document_chunks
    var wordCount: Int?             // From document_chunks
    
    // New RAG Phase 3 hybrid properties
    var semanticScore: Double?
    var keywordScoreNormalized: Double?
    var finalHybridScore: Double?
    var retrievalMode: String?      // keywordOnly / vectorOnly / hybrid / keywordFallback
}

struct RetrievalTrace: Codable, Equatable, Hashable {
    let id: UUID
    let query: String
    let intent: String?
    let createdAt: Date
    let rankedCVChunks: [RetrievedChunk]      // ranked chunks before budget
    let rankedJDChunks: [RetrievedChunk]
    let includedCVChunks: [RetrievedChunk]    // chunks included in prompt after budget
    let includedJDChunks: [RetrievedChunk]
    let excludedCVChunks: [RetrievedChunk]    // chunks excluded by budget
    let excludedJDChunks: [RetrievedChunk]
    let cvWordsUsed: Int
    let jdWordsUsed: Int
    let cvWordBudget: Int
    let jdWordBudget: Int
    let retrievalLatencyMS: Double
    let emptyQueryFallbackUsed: Bool          // true if query was empty
    let zeroScoreFallbackUsed: Bool           // true if query not empty but all chunks scored 0
    
    // New RAG Phase 3 embedding properties
    var retrievalMode: String?                // keywordOnly / hybrid / vectorFallback
    var embeddingProvider: String?
    var embeddingModel: String?
    var embeddingCoveragePercent: Double?
    var queryEmbeddingGenerated: Bool = false
    var queryEmbeddingLatencyMS: Double?
    var vectorSearchLatencyMS: Double?
    var hybridSemanticWeight: Double = 0.7
    var hybridKeywordWeight: Double = 0.3
    var embeddingWarnings: [String] = []
    var fallbackReason: String?
}
