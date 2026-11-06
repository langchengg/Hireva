import Foundation
import GRDB
import Testing
@testable import Hireva

@MainActor
struct RAGFallbackFrozenSnapshotTests {
    @Test(.timeLimit(.minutes(1)))
    func frozenCardComputationKeepsItsSnapshotValueButDisplayRejectsDeletedSnapshot() async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database,
            questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: nil)
        do {
            let session = try makeSyntheticContextSession(app)
            app.currentSession = session
            let snapshotID = try #require(session.contextSnapshotID)
            let snapshot = try #require(try app.interviewContextRepository.snapshot(id: snapshotID))
            let question = DetectedQuestion(id: "frozen-rag-question", sessionID: session.id,
                transcriptSegmentID: nil, questionText: "Why do you want this role?",
                intent: .companyFit, answerStrategy: .directAnswer, confidence: 1,
                reason: "Synthetic frozen-card boundary fixture", shouldTrigger: true,
                questionComplete: true, modelName: "fixture", promptVersion: "fixture", createdAt: Date())
            try app.suggestionRepository.saveDetectedQuestion(question)
            let startedAt = Date()
            let generationID = "frozen-rag-generation"
            let context = GenerationExecutionContext.make(session: session, question: question,
                generationID: generationID, triggerPath: .manualGenerate, provider: nil,
                retrievedContext: .init(cvChunks: [], jobDescriptionChunks: []),
                transcriptSnapshot: question.questionText, cvSummary: "", jdSummary: "",
                startedAt: startedAt, source: nil, speaker: nil, stage: .firstAnswer,
                interviewContextSnapshot: snapshot)
            app.activateGeneration(question: question, generationID: generationID,
                triggerPath: .manualGenerate, requestStart: startedAt, source: nil, speaker: nil)
            try #require(app.generationCoordinator.canPublish(context.identity))
            let beforeDeletion = app.makeRAGFallbackCard(context: context,
                cardID: "frozen-rag-card", isSoft: true)
            try #require(!beforeDeletion.sayFirst.isEmpty)
            try #require(!beforeDeletion.candidateEvidenceIDs.isEmpty)
            try #require(beforeDeletion.contextIsolationStatus == "matched")

            // Delete only this isolated synthetic snapshot. This is a boundary
            // probe, not a bypass of the production session-deletion policy.
            try await database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM interview_context_snapshots WHERE id = ?", arguments: [snapshotID])
            }
            #expect(try app.interviewContextRepository.snapshot(id: snapshotID) == nil)
            #expect(app.generationCoordinator.canPublish(context.identity),
                "The computation probe keeps identity current so the display's separate DB admission is exercised.")
            let computed = app.makeRAGFallbackCard(context: context,
                cardID: "frozen-rag-card", isSoft: true)
            #expect(computed.sayFirst == beforeDeletion.sayFirst,
                "Card computation must use the frozen snapshot value instead of querying a later DB state.")
            #expect(computed.keyPoints == beforeDeletion.keyPoints)
            #expect(computed.candidateEvidenceIDs == beforeDeletion.candidateEvidenceIDs)
            #expect(computed.opportunityEvidenceIDs == beforeDeletion.opportunityEvidenceIDs)
            #expect(computed.groundingDecision == beforeDeletion.groundingDecision)
            #expect(computed.contextIsolationStatus == "matched")
            #expect(computed.contextSnapshotID == snapshotID)
            #expect(computed.candidateProfileID == snapshot.candidateProfileID)
            #expect(computed.candidateProfileVersion == snapshot.candidateProfileVersion)

            // A computed value is not publication permission. Exercise the real
            // display boundary: the deleted snapshot must never be restored.
            let published = app.displaySuggestionIfAligned(computed, question: question,
                generationID: generationID, triggerPath: .manualGenerate)
            #expect(!published)
            #expect(app.currentSuggestion == nil)
            #expect(app.lastAlignmentError == "Suggestion context snapshot could not be loaded.")
            #expect(try app.suggestionRepository.suggestions(sessionID: session.id).isEmpty)
            await app.shutdownForTesting()
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
            try database.close()
        } catch {
            await app.shutdownForTesting()
            try? database.close()
            throw error
        }
    }

    private func makeSyntheticContextSession(_ app: AppState) throws -> InterviewSession {
        // Same declared synthetic evidence as the established first-answer
        // fallback fixtures; no actual candidate record, model or cloud request.
        let sourceID = "frozen-rag-synthetic-source"
        let rows: [(String, String, EvidenceType)] = [
            ("project", "My LeoRover project was an autonomous object retrieval robot using ROS2, YOLOv8 perception, navigation, target localisation, and manipulation on a real robot.", .project),
            ("role", "I want this role because it connects my robotics, AI, perception, and real-world deployment experience with the team's product direction.", .goal),
            ("integration", "I integrated robot perception, localisation, navigation, and manipulation through ROS2.", .experience),
            ("result", "The LeoRover project result was a complete perception-to-action pipeline on a real robot, and I learned that localisation and timing made integration the main reliability challenge.", .project)
        ]
        let evidence = rows.map { id, statement, type in ProfileEvidence(
            id: "frozen-rag-" + id, statement: statement, sourceDocumentID: sourceID,
            sourceChunkID: id, sourceSpan: statement, confidence: 1,
            evidenceType: type, explicitness: .explicit) }
        let profileID = "frozen-rag-synthetic-profile"
        try app.interviewContextRepository.saveCandidateProfile(.init(id: profileID,
            displayName: "Synthetic Frozen RAG Candidate", sourceDocumentIDs: [sourceID],
            education: [], experience: [evidence[2]], projects: [evidence[0], evidence[3]],
            skills: [], publications: [], achievements: [], declaredGaps: [], goals: [evidence[1]],
            generatedSummary: nil, version: 1, updatedAt: Date(timeIntervalSince1970: 1)))
        app.refreshAll()
        app.selectCandidateProfile(profileID)
        app.selectInterviewDomain(.roboticsResearch)
        return try app.createContextBoundSession(mode: .mock, title: "Synthetic frozen RAG boundary")
    }
}
