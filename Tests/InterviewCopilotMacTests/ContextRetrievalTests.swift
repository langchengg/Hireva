import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite
struct ContextRetrievalTests {
    @Test
    func retrievalRanksMatchingCVAndJDChunksWithinBudgets() throws {
        let database = try makeTemporaryDatabase()
        let documents = DocumentRepository(database: database)
        _ = try documents.saveDocument(
            type: .cv,
            title: "Resume",
            content: """
            Robotics project: built a language-conditioned grasping pipeline with MuJoCo evaluation and VLM reranking.

            Web project: created a billing dashboard and support tooling.
            """
        )
        _ = try documents.saveDocument(
            type: .jobDescription,
            title: "Robotics JD",
            content: """
            Requirements include robot learning, simulation evaluation, vision-language model reasoning, and production communication.
            """
        )

        let service = SimpleContextRetrievalService(documentRepository: documents)
        let context = try service.retrieveContext(
            question: "Walk me through your language-conditioned robotic grasping work",
            intent: .projectDeepDive,
            maxCVWords: 20,
            maxJDWords: 20
        )

        #expect(context.cvChunks.first?.content.lowercased().contains("robotics") == true)
        #expect(context.cvChunks.map(\.content).joined(separator: " ").split(separator: " ").count <= 20)
        #expect(context.jobDescriptionChunks.map(\.content).joined(separator: " ").split(separator: " ").count <= 20)
    }

    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterviewCopilotMacRetrievalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
}
