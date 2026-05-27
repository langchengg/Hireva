import Foundation

struct RetrievedChunk: Codable, Identifiable, Equatable, Hashable {
    let id: String                  // document_chunks.id
    let documentID: String
    let documentType: DocumentType
    let chunkIndex: Int
    let contentPreview: String      // first ~80 chars
    let fullContent: String
    let keywords: [String]
    let score: Double               // keywordScore + contentScore
    let keywordOverlapCount: Int
    let contentOverlapCount: Int
    let rank: Int                   // 1-based position after sorting
    var isIncludedInPrompt: Bool    // Track if actually sent to LLM
    var sectionTitle: String?       // From document_chunks
    var wordCount: Int?             // From document_chunks
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
}
