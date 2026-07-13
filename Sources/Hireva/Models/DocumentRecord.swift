import Foundation

enum DocumentType: String, CaseIterable, Identifiable, Codable {
    case cv
    case jobDescription = "job_description"
    case additionalNotes = "additional_notes"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cv:
            return "CV / Resume"
        case .jobDescription:
            return "Job Description"
        case .additionalNotes:
            return "Additional Notes"
        }
    }

    var shortTitle: String {
        switch self {
        case .cv:
            return "CV"
        case .jobDescription:
            return "JD"
        case .additionalNotes:
            return "Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .cv:
            return "doc.text"
        case .jobDescription:
            return "briefcase"
        case .additionalNotes:
            return "note.text"
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
    var sanitizedContent: String?
    var sanitizedPreview: String?
    var sanitizationWarnings: String?
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
