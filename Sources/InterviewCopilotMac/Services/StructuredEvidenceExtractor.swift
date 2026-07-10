import CommonCrypto
import Foundation

struct StructuredEvidenceExtractor {
    func extract(
        documentID: String,
        classification: DocumentClassification,
        content: String,
        persistedChunks: [DocumentChunk] = []
    ) -> StructuredEvidenceExtraction {
        let lines = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var currentSection = ""
        var candidate: [ProfileEvidence] = []
        var opportunity: [ProfileEvidence] = []

        for (index, line) in lines.enumerated() {
            if isSectionHeading(line) {
                currentSection = line.lowercased()
                continue
            }
            let type = evidenceType(line: line, section: currentSection, classification: classification)
            let explicitness: EvidenceExplicitness = type == .other ? .inferred : .explicit
            let evidence = ProfileEvidence(
                id: "evidence-\(shortHash("\(documentID)|\(index)|\(line)"))",
                statement: line,
                sourceDocumentID: documentID,
                sourceChunkID: sourceChunkID(for: line, lineIndex: index, chunks: persistedChunks),
                sourceSpan: line,
                confidence: type == .other ? 0.55 : 0.9,
                evidenceType: type,
                explicitness: explicitness
            )
            if classification.isCandidateSource {
                candidate.append(evidence)
            } else if classification.isOpportunitySource {
                opportunity.append(evidence)
            }
        }

        return StructuredEvidenceExtraction(
            documentID: documentID,
            documentHash: contentHash(content),
            classification: classification,
            candidateEvidence: candidate,
            opportunityEvidence: opportunity,
            uncertainCount: (candidate + opportunity).filter { $0.explicitness == .inferred }.count
        )
    }

    private func sourceChunkID(for line: String, lineIndex: Int, chunks: [DocumentChunk]) -> String? {
        guard !chunks.isEmpty else { return "unpersisted-chunk-\(lineIndex)" }
        let normalizedLine = QuestionTextUtilities.collapse(line).lowercased()
        if let exactContainer = chunks.first(where: {
            QuestionTextUtilities.collapse($0.content).lowercased().contains(normalizedLine)
        }) {
            return exactContainer.id
        }
        return chunks[min(lineIndex, chunks.count - 1)].id
    }

    func cacheKey(
        content: String,
        classification: DocumentClassification,
        ownerVersion: Int
    ) -> String {
        shortHash("\(contentHash(content))|\(classification.rawValue)|\(ownerVersion)")
    }

    func contentHash(_ content: String) -> String {
        shortHash(content)
    }

    private func evidenceType(
        line: String,
        section: String,
        classification: DocumentClassification
    ) -> EvidenceType {
        let lower = line.lowercased()
        if classification.isOpportunitySource {
            if section.contains("required") || lower.contains("required skill") || lower.contains("must have") {
                return .requiredSkill
            }
            if section.contains("preferred") || lower.contains("preferred") || lower.contains("nice to have") {
                return .preferredSkill
            }
            if section.contains("research") || lower.contains("research topic") {
                return .researchTopic
            }
            if section.contains("evaluation") || lower.contains("evaluation criteria") || lower.contains("we assess") {
                return .evaluationCriterion
            }
            if section.contains("responsibil") || lower.contains("responsibilit") || lower.contains("you will") {
                return .responsibility
            }
            return .responsibility
        }

        let gapWords = ["limited", "no experience", "not yet", "lack of", "development area", "need to develop"]
        if section.contains("gap") || section.contains("development") || gapWords.contains(where: lower.contains) {
            return .declaredGap
        }
        if section.contains("education") || section.contains("degree") || lower.contains("university") || lower.contains("bsc") || lower.contains("msc") || lower.contains("phd") {
            return .education
        }
        if section.contains("project") || lower.contains("built ") || lower.contains("developed ") || lower.contains("implemented ") {
            return .project
        }
        if section.contains("skill") || lower.contains("proficient") || lower.contains("technologies") || lower.contains("tools") {
            return .skill
        }
        if section.contains("publication") || lower.contains("published") {
            return .publication
        }
        if section.contains("achievement") || lower.contains("award") || lower.contains("improved") || lower.contains("reduced") {
            return .achievement
        }
        if section.contains("goal") || lower.contains("aim to") || lower.contains("career goal") {
            return .goal
        }
        if section.contains("experience") || section.contains("employment") || lower.contains("worked") || lower.contains("led ") {
            return .experience
        }
        return .other
    }

    private func isSectionHeading(_ line: String) -> Bool {
        let normalized = line.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        let known = [
            "education", "experience", "employment", "projects", "project", "skills", "publications",
            "achievements", "goals", "development area", "skill gaps", "required skills", "preferred skills",
            "responsibilities", "research topics", "evaluation criteria"
        ]
        return known.contains(normalized)
    }

    private func shortHash(_ text: String) -> String {
        let data = Data(text.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
