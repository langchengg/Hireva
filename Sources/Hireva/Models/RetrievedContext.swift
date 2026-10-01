import Foundation

/// RAG context selected from CV, job description, and notes.
///
/// Retrieved context is supporting evidence only. Prompt builders and alignment
/// guards must keep the detected question as the primary task.
struct RetrievedContext: Hashable {
    var cvChunks: [DocumentChunk]
    var jobDescriptionChunks: [DocumentChunk]
    var additionalNotesChunks: [DocumentChunk] = []

    /// Citations reflect only the already-filtered frozen provider input.
    var frozenPromptCitations: [RetrievedChunk] {
        let promptChunks = cvChunks + jobDescriptionChunks + additionalNotesChunks
        return promptChunks.enumerated().map { index, chunk in
            RetrievedChunk(
                id: chunk.id, documentID: chunk.documentID, documentType: chunk.documentType,
                chunkIndex: chunk.chunkIndex, contentPreview: String(chunk.content.prefix(80)),
                fullContent: chunk.content, keywords: chunk.keywords, score: 1,
                keywordOverlapCount: 0, contentOverlapCount: 0, rank: index + 1,
                isIncludedInPrompt: true, sectionTitle: chunk.sectionTitle,
                wordCount: chunk.wordCount, retrievalMode: "frozen_prompt"
            )
        }
    }

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
