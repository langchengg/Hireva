import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite
struct OutputQualityTests {
    
    @Test
    func sanitizerPreservesCustomArgumentsAndStripsPreamble() throws {
        let input = """
        \\documentclass{resume}
        \\usepackage{hidelinks}
        \\geometry{left=0.4in}
        \\begin{document}
        \\rSubsection{Robotics Project}{May 2026}{http://grasp.ai}{DeepMind}
        This is a project description.
        \\end{document}
        """
        let result = DocumentTextSanitizer.sanitize(input)
        
        #expect(result.wasSanitized == true)
        let sanitized = result.sanitizedContent
        
        // Assert preamble discarded
        #expect(!sanitized.contains("documentclass"))
        #expect(!sanitized.contains("usepackage"))
        #expect(!sanitized.contains("geometry"))
        
        // Assert arguments of unknown custom macro preserved
        #expect(sanitized.contains("Robotics Project"))
        #expect(sanitized.contains("May 2026"))
        #expect(sanitized.contains("http://grasp.ai"))
        #expect(sanitized.contains("DeepMind"))
        #expect(sanitized.contains("This is a project description"))
    }
    
    @Test
    func sanitizerStripsLatexCommentSeparators() throws {
        let input = """
        %----------------------------------------------------------------------------------------
        % PROFILE
        %----------------------------------------------------------------------------------------
        MSc Robotics student focused on embodied AI and ROS2 systems.
        """
        let result = DocumentTextSanitizer.sanitize(input)
        
        #expect(result.wasSanitized == true)
        #expect(!result.sanitizedContent.contains("%"))
        #expect(!result.sanitizedContent.contains("PROFILE"))
        #expect(result.sanitizedContent.contains("MSc Robotics student"))
    }

    @Test
    func latexPollutionDetectorIgnoresPlainTechnicalWords() throws {
        let plain = "Converted target masks into 3D object geometry for grasp planning."
        let latex = #"Candidate used \geometry{left=0.4in} in a raw LaTeX resume."#

        #expect(DocumentTextSanitizer.containsResidualLatexFormattingNoise(plain) == false)
        #expect(DocumentTextSanitizer.containsResidualLatexFormattingNoise(latex) == true)
    }
    
    @Test
    func ragChunksAfterRebuildContainNoLaTeXPreamble() async throws {
        let database = try makeTemporaryDatabase()
        let repo = DocumentRepository(database: database)
        
        let docContent = """
        \\documentclass{resume}
        \\usepackage{geometry}
        \\begin{document}
        Candidate worked on robotics and VLM grasping thesis.
        \\end{document}
        """
        
        // Save document (which sanitizes using DocumentTextSanitizer)
        _ = try repo.saveDocument(type: .cv, title: "Resume", content: docContent)
        
        // Check chunks directly
        let chunks = try repo.chunks(type: .cv)
        #expect(!chunks.isEmpty)
        for chunk in chunks {
            #expect(!chunk.content.contains("documentclass"))
            #expect(!chunk.content.contains("usepackage"))
            #expect(!chunk.content.contains("geometry"))
        }
    }
    
    @Test
    func answerValidatorFiltersMetaInstructions() throws {
        let badSayFirst = "Highlight alignment with field service role, emphasizing practical engineering interest, travel willingness, customer focus, and learning mindset. Use work authorization as a plus."
        
        #expect(AnswerQualityValidator.isValidField(badSayFirst, isSayFirst: true) == false)
        
        let clean = AnswerQualityValidator.localCleanupAnswer(badSayFirst)
        #expect(!clean.contains("Highlight alignment"))
        #expect(!clean.contains("emphasizing practical"))
        // Check it has been cleaned to speakable first-person text
        #expect(clean.isEmpty || clean.contains("I am") || clean.contains("My background") || AnswerQualityValidator.isValidField(clean, isSayFirst: true))
    }
    
    @Test
    func answerValidatorValidatesCardFields() throws {
        let card = SuggestionCard(
            id: UUID().uuidString,
            sessionID: UUID().uuidString,
            questionID: nil,
            strategy: "Direct Answer",
            sayFirst: "I want this role because of my passion for hands-on systems.",
            keyPoints: ["\\documentclass{resume}", "\\textbf{Solid} foundation"],
            followUpReady: ["\\usepackage{geometry}", "Ask about ROS2"],
            confidence: 0.9,
            caution: "None",
            evidenceUsed: ["formatting"],
            riskLevel: .low,
            modelName: "deepseek-v4-flash",
            promptVersion: "v1",
            rawJSON: nil,
            createdAt: Date()
        )
        
        // Validate card fields
        let isValid = AnswerQualityValidator.isValid(
            sayFirst: card.sayFirst,
            keyPoints: card.keyPoints,
            followUpReady: card.followUpReady,
            caution: card.caution
        )
        // Since keyPoints and followUpReady contain LaTeX preamble keywords, they should be invalid
        #expect(isValid == false)
    }
    
    @Test
    func whyRoleRetrievalExcludesFormattingAndLimitsCVChunks() async throws {
        let database = try makeTemporaryDatabase()
        let repo = DocumentRepository(database: database)
        
        // Save formatting CV chunk
        _ = try repo.saveDocument(
            type: .cv,
            title: "Header",
            content: "Email: candidate@grasp.ai | Phone: 123-456-7890 | linkedin.com/in/candidate | github.com/candidate"
        )
        
        // Save real content CV chunks
        _ = try repo.saveDocument(
            type: .cv,
            title: "Resume Content",
            content: """
            Robotics project: built a language-conditioned grasping pipeline with MuJoCo.
            
            Work experience: software engineer building control loops for autonomous rovers.
            
            Education: Master of Science in Robotics Engineering from top university.
            """
        )
        
        // Save Job Description
        _ = try repo.saveDocument(
            type: .jobDescription,
            title: "Robotics Role",
            content: "We are seeking a systems engineer to build robotic grasping software using C++ and ROS2."
        )
        
        let settings = AppSettings.default
        let service = HybridContextRetrievalService(
            documentRepository: repo,
            settingsProvider: { settings },
            embeddingProviderResolver: { nil }
        )
        
        let (context, trace) = try await service.retrieveContextWithTrace(
            question: "Why do you want this role?",
            intent: QuestionIntent.companyFit,
            maxCVWords: 1500,
            maxJDWords: 1000,
            strategy: AnswerStrategy.directAnswer
        )
        
        // Assert whyRole profile was matched
        #expect(trace.intent == "company_fit")
        
        // Check formatting chunks excluded
        for chunk in context.cvChunks {
            #expect(!HybridContextRetrievalService.isFormattingChunk(chunk.content))
        }
        
        // Check CV chunks capped to at most 2
        #expect(context.cvChunks.count <= 2)
    }
    
    @Test
    @MainActor
    func duplicateQuestionSuppressesDuplicateSuggestionButKeepsTranscript() async throws {
        let database = try makeTemporaryDatabase()
        let appState = AppState(database: database)
        
        let qText = "Tell me about yourself."
        
        // First detection
        let detected1 = DetectedQuestion(
            id: UUID().uuidString,
            sessionID: UUID().uuidString,
            questionText: qText,
            intent: QuestionIntent.behavioral,
            answerStrategy: AnswerStrategy.directAnswer,
            confidence: 0.9,
            shouldTrigger: true,
            questionComplete: true,
            modelName: "Test",
            promptVersion: "v1",
            createdAt: Date()
        )
        
        let isDup1 = appState.isDuplicateAutoQuestion(detected1.questionText)
        #expect(isDup1 == false)
        
        // Second detection within 20s
        let detected2 = DetectedQuestion(
            id: UUID().uuidString,
            sessionID: detected1.sessionID,
            questionText: qText,
            intent: QuestionIntent.behavioral,
            answerStrategy: AnswerStrategy.directAnswer,
            confidence: 0.9,
            shouldTrigger: true,
            questionComplete: true,
            modelName: "Test",
            promptVersion: "v1",
            createdAt: Date()
        )
        
        let isDup2 = appState.isDuplicateAutoQuestion(detected2.questionText)
        #expect(isDup2 == true)
        #expect(!appState.shouldShowBlockingAnswerSpinner)
        #expect(!appState.isActionLoading(ActionID.generateAnswer))
    }

    @Test
    @MainActor
    func followUpQuestionContainingPreviousQuestionIsNotDuplicate() async throws {
        let database = try makeTemporaryDatabase()
        let appState = AppState(database: database)

        let first = "What is your project?"
        let followUp = "What is your project? What is your goal?"

        #expect(appState.isDuplicateAutoQuestion(first) == false)
        #expect(appState.isDuplicateAutoQuestion(followUp) == false)
        #expect(appState.isDuplicateAutoQuestion(followUp) == true)
    }
    
    @Test
    @MainActor
    func switchingToSystemAudioOnlyDoesNotDeleteHistoricalTranscript() async throws {
        let database = try makeTemporaryDatabase()
        let appState = AppState(database: database)
        
        let session = try appState.sessionRepository.createSession(mode: .microphone)
        appState.currentSession = session
        
        // Add historical segments
        let segment = TranscriptSegment(
            id: UUID().uuidString,
            sessionID: session.id,
            source: .microphone,
            speaker: .candidate,
            text: "Hello, I am ready for the interview.",
            createdAt: Date()
        )
        appState.transcriptSegments.append(segment)
        try appState.transcriptRepository.saveSegment(segment)
        
        // Simulate startListening cleanup directly
        appState.lastSystemAudioASRPartialTranscript = ""
        appState.microphoneDiagnostics.stopMicTest()
        
        // Check that historical segment is kept and level meters / partials are cleared
        #expect(appState.transcriptSegments.count == 1)
        #expect(appState.transcriptSegments.first?.text == "Hello, I am ready for the interview.")
        #expect(appState.lastSystemAudioASRPartialTranscript.isEmpty)
        #expect(appState.microphoneDiagnostics.decibels == -90)
    }
    
    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutputQualityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
}
