import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
struct TestSuite1Tests {
    @Test
    @MainActor
    func testSuite1_OnboardingAndDocuments() async throws {
        print("=== Test Suite 1: Onboarding and Documents ===")
        
        let database = try makeTemporaryDatabase()
        let appState = AppState(database: database)
        defer { try? database.close() }
        
        // Knowledge/coding practice is available without personal materials.
        // The evidence gate applies to personal claims, not application entry.
        #expect(appState.onboardingComplete)
        #expect(appState.liveBlockedReason == nil)
        #expect(!appState.hasCV)
        #expect(InterviewTaskDescriptor(question: "Tell me about yourself").requiresPersonalEvidence)
        #expect(!InterviewTaskDescriptor(question: "Explain binary search").requiresPersonalEvidence)

        // 1.2 Add CV and JD
        let cvText = "Candidate: Jane Doe\nExperience: Robotics Engineer for 5 years.\nSkills: Python, C++, ROS, Control Systems."
        let jdText = "Job: Robotics Architect\nRequirements: 3+ years experience with C++, Python, ROS, and motion planning algorithms."
        
        appState.saveDocument(type: DocumentType.cv, title: "CV / Resume", content: cvText)
        appState.saveDocument(type: DocumentType.jobDescription, title: "Job Description", content: jdText)

        appState.refreshAll()
        await appState.rebuildAutomaticInterviewContext(useLocalQwen: false)

        #expect(appState.hasCV, "CV should be successfully saved.")
        #expect(appState.hasJD, "JD should be successfully saved.")
        #expect(appState.onboardingComplete, "Onboarding should be complete after saving both documents.")
        #expect(appState.liveBlockedReason == nil, "Live Interview entry should no longer be blocked.")
        print("  [1.2] Onboarding completed successfully. accessible = true")
        
        // 1.3 Document retrieval
        let documentsRepo = DocumentRepository(database: database)
        let contextService = SimpleContextRetrievalService(documentRepository: documentsRepo)
        let context = try await contextService.retrieveContext(
            question: "ROS control robotics",
            intent: QuestionIntent.technical,
            maxCVWords: 1500,
            maxJDWords: 1000
        )
        
        #expect(!context.cvChunks.isEmpty, "Should retrieve relevant CV chunks.")
        #expect(!context.jobDescriptionChunks.isEmpty, "Should retrieve relevant JD chunks.")
        print("  [1.3] Context retrieval works. CV chunks: \(context.cvChunks.count), JD chunks: \(context.jobDescriptionChunks.count)")
        await appState.shutdownForTesting()
    }

    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestSuite1Database-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
}
