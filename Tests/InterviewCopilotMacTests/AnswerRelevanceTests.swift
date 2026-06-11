import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite(.serialized)
@MainActor
struct AnswerRelevanceTests {
    @Test
    func promptsPutFrozenQuestionBeforeContextForAllInterviewQuestions() {
        for fixture in Self.fixtures {
            let question = makeQuestion(fixture.question)
            let context = misleadingContext()
            let snapshot = AnswerRelevancePolicy.promptSnapshot(
                question: question,
                context: context,
                transcriptContext: "Interviewer: previous unrelated question about background.",
                cvSummary: "Candidate has MSc Robotics, LeoRover, VLA and ROS2 experience.",
                jdSummary: "Robotics software team building deployed perception systems.",
                stage: .firstAnswer
            )

            #expect(snapshot.questionTextSnapshot == fixture.question)
            #expect(snapshot.questionIntent == fixture.intent)
            #expect(snapshot.prompt.hasPrefix("""
            CURRENT QUESTION TO ANSWER:
            "\(fixture.question)"
            """))
            #expect(snapshot.prompt.range(of: "CURRENT QUESTION TO ANSWER:")!.lowerBound < snapshot.prompt.range(of: "RELEVANT CONTEXT:")!.lowerBound)
            #expect(snapshot.prompt.contains("Answer this exact question directly in first person."))
            #expect(snapshot.prompt.contains(fixture.intent.rawValue))
        }
    }

    @Test
    func intentSpecificFallbacksDirectlyAnswerNineInterviewQuestions() {
        for fixture in Self.fixtures {
            let question = makeQuestion(fixture.question)
            let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
            let combined = ([fallback.sayFirst] + fallback.keyPoints).joined(separator: " ")
            let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
                questionText: fixture.question,
                answerText: combined
            )

            #expect(alignment.verdict == .aligned || alignment.verdict == .weaklyAligned)
            for expected in fixture.mustContain {
                #expect(combined.localizedCaseInsensitiveContains(expected))
            }
        }
    }

    @Test
    func intentFilteringKeepsRAGSubordinateToQuestion() {
        let context = misleadingContext()

        let candidateQuestionContext = AnswerRelevancePolicy.filterContext(
            context,
            intent: .candidateQuestions
        )
        #expect(candidateQuestionContext.cvChunks.isEmpty)
        #expect(candidateQuestionContext.promptText.localizedCaseInsensitiveContains("MSc Robotics") == false)

        let skillContext = AnswerRelevancePolicy.filterContext(
            context,
            intent: .skillComfort
        )
        #expect(skillContext.promptText.localizedCaseInsensitiveContains("Python"))
        #expect(skillContext.promptText.localizedCaseInsensitiveContains("ROS2"))
        #expect(skillContext.promptText.localizedCaseInsensitiveContains("C++"))

        let modelContext = AnswerRelevancePolicy.filterContext(
            context,
            intent: .modelComparison
        )
        #expect(modelContext.promptText.localizedCaseInsensitiveContains("diffusion"))
        #expect(modelContext.promptText.localizedCaseInsensitiveContains("autoregressive"))
        #expect(modelContext.promptText.localizedCaseInsensitiveContains("flow-matching"))
    }

    @Test
    func semanticGuardRejectsMismatchedProviderAnswerAndPreservesFallback() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "AnswerRelevanceGuard")
        let appState = AppState(database: database)
        let session = try appState.sessionRepository.createSession(mode: .mock)
        let question = makeQuestion("Do you have any questions for us?", sessionID: session.id)
        try appState.suggestionRepository.saveDetectedQuestion(question)
        appState.setActiveQuestionForTesting(question)

        let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
        var fallbackCard = SuggestionCard(
            id: "candidate-question-fallback",
            sessionID: session.id,
            questionID: question.id,
            strategy: "Local intent fallback",
            sayFirst: fallback.sayFirst,
            keyPoints: fallback.keyPoints,
            followUpReady: [],
            confidence: 0.7,
            caution: nil,
            evidenceUsed: [],
            riskLevel: .low,
            modelName: "local",
            promptVersion: "test",
            rawJSON: nil,
            createdAt: Date()
        )
        fallbackCard.questionText = question.questionText
        #expect(appState.applySuggestionIfAlignedForTesting(fallbackCard, question: question, generationID: nil))

        var wrongProviderCard = fallbackCard
        wrongProviderCard.id = "wrong-provider-card"
        wrongProviderCard.sayFirst = "I am currently studying MSc Robotics at the University of Manchester, with a computer science background and robotics experience."
        wrongProviderCard.keyPoints = ["MSc Robotics", "Computer science background"]
        wrongProviderCard.providerName = "DeepSeek"
        wrongProviderCard.sayFirstSource = "deepseek_stream"

        #expect(appState.applySuggestionIfAlignedForTesting(wrongProviderCard, question: question, generationID: nil) == false)
        #expect(appState.currentSuggestion?.id == "candidate-question-fallback")
        #expect(appState.currentSuggestion?.sayFirst == fallback.sayFirst)
        #expect(appState.lastAlignmentError.localizedCaseInsensitiveContains("using fallback"))
    }

    private struct Fixture {
        var question: String
        var intent: AnswerRelevanceIntent
        var mustContain: [String]
    }

    private static let fixtures: [Fixture] = [
        Fixture(
            question: "Could you tell me a little bit about yourself and what brought you into robotics?",
            intent: .tellMeAboutYourself,
            mustContain: ["MSc Robotics", "robotics"]
        ),
        Fixture(
            question: "Could you walk me through your LeoRover project?",
            intent: .projectWalkthrough,
            mustContain: ["LeoRover", "ROS2", "YOLOv8", "navigation", "manipulation"]
        ),
        Fixture(
            question: "What was the hardest technical challenge you faced?",
            intent: .technicalChallenge,
            mustContain: ["noisy", "localisation", "real robot"]
        ),
        Fixture(
            question: "How did you handle noisy detections or localisation errors?",
            intent: .errorHandling,
            mustContain: ["filtering", "repeated observations", "recovery"]
        ),
        Fixture(
            question: "Why did the diffusion decoder perform better in your MuJoCo evaluation?",
            intent: .modelComparison,
            mustContain: ["diffusion", "autoregressive", "flow-matching", "smoother", "seven out of ten"]
        ),
        Fixture(
            question: "What would you change first if you had another month?",
            intent: .improvementPlan,
            mustContain: ["evaluation", "failure cases", "reranking"]
        ),
        Fixture(
            question: "Why do you want to join our team?",
            intent: .whyRole,
            mustContain: ["role", "robotics", "deployment"]
        ),
        Fixture(
            question: "How comfortable are you with Python, C++, and ROS2?",
            intent: .skillComfort,
            mustContain: ["Python", "C++", "ROS2"]
        ),
        Fixture(
            question: "Do you have any questions for us?",
            intent: .candidateQuestions,
            mustContain: ["ask", "team", "deployment"]
        )
    ]

    private func makeQuestion(_ text: String, sessionID: String = "answer-relevance-session") -> DetectedQuestion {
        DetectedQuestion(
            id: "answer-relevance-\(UUID().uuidString)",
            sessionID: sessionID,
            transcriptSegmentID: nil,
            questionText: text,
            intent: .unclear,
            answerStrategy: .directAnswer,
            confidence: 0.95,
            reason: "Answer relevance fixture",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "test",
            promptVersion: "test",
            createdAt: Date()
        )
    }

    private func misleadingContext() -> RetrievedContext {
        RetrievedContext(
            cvChunks: [
                chunk("self", "Education: MSc Robotics at the University of Manchester with a computer science background and robotics interest.", .cv),
                chunk("leorover", "LeoRover autonomous object retrieval robot using ROS2, YOLOv8, target localisation, navigation, and manipulation.", .cv),
                chunk("challenge", "Hardest challenge: noisy perception, localisation instability, timing mismatch, and unpredictable real robot execution.", .cv),
                chunk("noise", "Noisy detections were handled with filtering, repeated observations, stability thresholds, retry, repositioning, and recovery behaviour.", .cv),
                chunk("vla", "VLA MuJoCo evaluation compared diffusion, autoregressive, and flow-matching decoders; diffusion gave smoother continuous actions and seven out of ten successful grasps.", .cv),
                chunk("skills", "Skills: Python, ROS2, C++, robotics projects, control coordination, experiment scripting, and performance-critical robotics systems.", .cv)
            ],
            jobDescriptionChunks: [
                chunk("jd", "Robotics software team focused on perception, real-world deployment, evaluation, reliability, and success criteria.", .jobDescription)
            ]
        )
    }

    private func chunk(_ id: String, _ content: String, _ type: DocumentType) -> DocumentChunk {
        DocumentChunk(
            id: id,
            documentID: "\(type.rawValue)-doc",
            documentType: type,
            chunkIndex: 0,
            content: content,
            keywords: TextChunker.tokenize(content),
            sectionTitle: id,
            wordCount: content.split(whereSeparator: \.isWhitespace).count,
            metadataJSON: nil,
            createdAt: Date()
        )
    }
}
