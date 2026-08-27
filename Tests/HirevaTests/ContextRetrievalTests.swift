import Foundation
import Testing
@testable import Hireva

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
            Event ingestion project: built a schema-aware processing pipeline with deterministic replay evaluation and transformer reranking.

            Web project: created a billing dashboard and support tooling.
            """
        )
        _ = try documents.saveDocument(
            type: .jobDescription,
            title: "Platform Engineer Role",
            content: """
            Requirements include event processing, replay evaluation, transformer reasoning, and production communication.
            """
        )

        let service = SimpleContextRetrievalService(documentRepository: documents)
        let context = try await service.retrieveContext(
            question: "Walk me through your schema-aware event-processing pipeline",
            intent: .projectDeepDive,
            maxCVWords: 20,
            maxJDWords: 20
        )

        #expect(context.cvChunks.first?.content.lowercased().contains("event ingestion") == true)
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
            Data platform engineer with deep experience in Swift, SQL, and transformer models.

            Event classification service with deterministic replay evaluation.

            Embedded systems programmer using C and microcontrollers.
            """
        )

        let service = SimpleContextRetrievalService(documentRepository: documents)

        // 1. Test query with match and budget exclusion
        let (_, trace) = try await service.retrieveContextWithTrace(
            question: "data platform Swift transformer service",
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
        #expect(trace.includedCVChunks.first?.fullContent.contains("Data platform") == true)

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
            .appendingPathComponent("HirevaRetrievalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
}
