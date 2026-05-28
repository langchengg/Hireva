import Foundation

enum DocumentType: String, CaseIterable, Identifiable, Codable {
    case cv
    case jobDescription = "job_description"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cv:
            return "CV / Resume"
        case .jobDescription:
            return "Job Description"
        }
    }
}

struct DocumentRecord: Identifiable, Hashable, Codable {
    var id: String
    var type: DocumentType
    var title: String
    var content: String
    var createdAt: Date
    var updatedAt: Date
}

struct DocumentChunk: Identifiable, Hashable, Codable {
    var id: String
    var documentID: String
    var documentType: DocumentType
    var chunkIndex: Int
    var content: String
    var keywords: [String]
    var sectionTitle: String?
    var wordCount: Int?
    var metadataJSON: String?
    var createdAt: Date
    
    // RAG Embedding fields
    var embedding: Data?
    var embeddingModel: String?
    var embeddingProvider: String?
    var embeddingDimension: Int?
    var embeddingContentHash: String?
    var embeddingCreatedAt: Date?
}
