import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite
struct ContextRetrievalTests {
    @Test
    func retrievalRanksMatchingCVAndJDChunksWithinBudgets() async throws {
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
        let context = try await service.retrieveContext(
            question: "Walk me through your language-conditioned robotic grasping work",
            intent: .projectDeepDive,
            maxCVWords: 20,
            maxJDWords: 20
        )

        #expect(context.cvChunks.first?.content.lowercased().contains("robotics") == true)
        #expect(context.cvChunks.map(\.content).joined(separator: " ").split(separator: " ").count <= 20)
        #expect(context.jobDescriptionChunks.map(\.content).joined(separator: " ").split(separator: " ").count <= 20)
    }

    @Test
    func retrievalTraceTelemetryAndBudgetExclusion() async throws {
        let database = try makeTemporaryDatabase()
        let documents = DocumentRepository(database: database)

        _ = try documents.saveDocument(
            type: .cv,
            title: "Resume",
            content: """
            Robotics engineer with deep experience in C++, ROS2, and vision-language models (VLM).

            Robotics grasping simulator in MuJoCo.

            Embedded systems programmer using C and microcontrollers.
            """
        )

        let service = SimpleContextRetrievalService(documentRepository: documents)

        // 1. Test query with match and budget exclusion
        let (_, trace) = try await service.retrieveContextWithTrace(
            question: "robotics ROS2 VLM",
            intent: .technical,
            maxCVWords: 12, // tight budget!
            maxJDWords: 15
        )

        #expect(trace.retrievalLatencyMS >= 0)
        #expect(trace.emptyQueryFallbackUsed == false)
        #expect(trace.zeroScoreFallbackUsed == false)
        #expect(trace.cvWordsUsed <= 12)

        // Verify that included chunks were flagged correctly and matches the context
        #expect(trace.includedCVChunks.count > 0)
        #expect(trace.includedCVChunks.allSatisfy { $0.isIncludedInPrompt == true })
        #expect(trace.includedCVChunks.first?.fullContent.contains("Robotics") == true)

        // Verify that budget-excluded chunks were identified and not included in prompt
        #expect(trace.excludedCVChunks.count > 0)
        #expect(trace.excludedCVChunks.allSatisfy { $0.isIncludedInPrompt == false })

        // 2. Test empty query fallback
        let (_, emptyTrace) = try await service.retrieveContextWithTrace(
            question: "",
            intent: .unclear,
            maxCVWords: 100,
            maxJDWords: 100
        )
        #expect(emptyTrace.emptyQueryFallbackUsed == true)
        #expect(emptyTrace.zeroScoreFallbackUsed == false)
        #expect(emptyTrace.rankedCVChunks.count > 0)
        #expect(emptyTrace.rankedCVChunks.first?.chunkIndex == 0)

        // 3. Test zero score fallback
        let (_, zeroTrace) = try await service.retrieveContextWithTrace(
            question: "unrelatedTermThatMatchesNothingAtAll",
            intent: .technical,
            maxCVWords: 100,
            maxJDWords: 100
        )
        #expect(zeroTrace.emptyQueryFallbackUsed == false)
        #expect(zeroTrace.zeroScoreFallbackUsed == true)
        #expect(zeroTrace.rankedCVChunks.count > 0)
        #expect(zeroTrace.rankedCVChunks.first?.chunkIndex == 0)
    }

    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterviewCopilotMacRetrievalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
}
