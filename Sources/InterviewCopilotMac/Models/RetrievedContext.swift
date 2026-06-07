import Foundation

struct RetrievedContext: Hashable {
    var cvChunks: [DocumentChunk]
    var jobDescriptionChunks: [DocumentChunk]
    var additionalNotesChunks: [DocumentChunk] = []

    var isEmpty: Bool {
        cvChunks.isEmpty && jobDescriptionChunks.isEmpty && additionalNotesChunks.isEmpty
    }

    var promptText: String {
        var sections: [String] = []
        if !cvChunks.isEmpty {
            sections.append("CV / Resume context:\n" + cvChunks.map { "- \($0.content)" }.joined(separator: "\n"))
        }
        if !jobDescriptionChunks.isEmpty {
            sections.append("Job description context:\n" + jobDescriptionChunks.map { "- \($0.content)" }.joined(separator: "\n"))
        }
        if !additionalNotesChunks.isEmpty {
            sections.append("Additional notes context:\n" + additionalNotesChunks.map { "- \($0.content)" }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }
}
