import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite(.serialized)
struct DocumentFormatTruthfulnessTests {
    @Test
    func unsupportedResumeFormatDoesNotCreateReadyProfile() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = DocumentRepository(database: database)

        do {
            _ = try repository.saveDocument(
                type: .cv,
                title: "synthetic-resume.pdf",
                content: "%PDF-1.7 synthetic binary placeholder that must not be treated as extracted resume evidence"
            )
            Issue.record("Expected PDF input to be rejected")
        } catch let error as DocumentIngestionError {
            #expect(error.reason == .documentFormatNotSupported)
        }

        #expect(try repository.document(type: .cv) == nil)
    }

    @Test
    func emptyExtractedResumeRequiresReview() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = DocumentRepository(database: database)
        let formattingOnly = String(repeating: "\\section{} ", count: 12)

        do {
            _ = try repository.saveDocument(
                type: .cv,
                title: "synthetic-resume.tex",
                content: formattingOnly
            )
            Issue.record("Expected formatting-only extraction to fail")
        } catch let error as DocumentIngestionError {
            #expect(error.reason == .documentExtractionFailed)
        }

        #expect(try repository.document(type: .cv) == nil)
    }

    @Test
    func jobDescriptionCannotBecomeCandidateExperience() {
        let content = "Responsibilities:\n- Build distributed services\n- Improve database performance"
        let extraction = StructuredEvidenceExtractor().extract(
            documentID: "synthetic-jd",
            classification: .jobDescription,
            content: content
        )

        #expect(extraction.candidateEvidence.isEmpty)
        #expect(!extraction.opportunityEvidence.isEmpty)
        let candidateOnly: Set<EvidenceType> = [
            .education, .experience, .project, .skill, .publication,
            .achievement, .declaredGap, .goal
        ]
        #expect(extraction.opportunityEvidence.allSatisfy { !candidateOnly.contains($0.evidenceType) })
    }
}
