import Foundation
import Testing
@testable import Hireva

@Suite
struct PromptContextBuilderTests {
    @Test
    func currentQuestionAppearsBeforeContextAndBackground() {
        let question = makeQuestion("Why did the diffusion model perform better than the autoregressive model?")

        let snapshot = PromptContextBuilder.generationRequestSnapshot(
            question: question,
            generationID: "generation-1",
            triggerPath: .autoDetect,
            source: .systemAudio,
            speaker: .interviewer,
            acceptedAt: Date(timeIntervalSince1970: 1_717_171_717),
            context: mixedContext(),
            transcriptContext: "Interviewer: Could you walk me through your LeoRover project?",
            cvSummary: "Candidate has robotics, LeoRover, and VLA policy experience.",
            jdSummary: "Robotics team focused on reliable deployed systems.",
            stage: .firstAnswer
        )

        #expect(snapshot.detectedQuestionID == question.id)
        #expect(snapshot.questionText == question.questionText)
        #expect(snapshot.promptPrimaryQuestion == question.questionText)
        #expect(snapshot.promptSnapshot.prompt.hasPrefix("""
        CURRENT QUESTION TO ANSWER:
        "\(question.questionText)"
        """))

        let prompt = snapshot.promptSnapshot.prompt
        let questionRange = prompt.range(of: "CURRENT QUESTION TO ANSWER:")
        let candidateRange = prompt.range(of: "Candidate summary:")
        let roleRange = prompt.range(of: "Target role summary:")
        let evidenceRange = prompt.range(of: "Selected local evidence:")
        let backgroundRange = prompt.range(of: "BACKGROUND FROM EARLIER INTERVIEW:")

        #expect(questionRange != nil)
        #expect(candidateRange != nil)
        #expect(roleRange != nil)
        #expect(evidenceRange != nil)
        #expect(backgroundRange != nil)
        if let questionRange, let candidateRange, let roleRange, let evidenceRange, let backgroundRange {
            #expect(questionRange.lowerBound < candidateRange.lowerBound)
            #expect(candidateRange.lowerBound < roleRange.lowerBound)
            #expect(roleRange.lowerBound < evidenceRange.lowerBound)
            #expect(evidenceRange.lowerBound < backgroundRange.lowerBound)
        }
    }

    @Test
    func previousTranscriptIsBackgroundAndCannotOverrideCurrentQuestion() {
        let question = makeQuestion("Why did the diffusion model perform better than the autoregressive model?")

        let snapshot = PromptContextBuilder.promptSnapshot(
            question: question,
            context: mixedContext(),
            transcriptContext: "Interviewer: Which part of the LeoRover pipeline was most fragile when moving from a clean demo to real robot execution?",
            cvSummary: "Candidate has robotics project experience.",
            jdSummary: "Robotics role.",
            stage: .firstAnswer
        )

        #expect(snapshot.prompt.localizedCaseInsensitiveContains("Previous transcript is background only and must not change the question."))
        #expect(snapshot.previousQuestionText?.localizedCaseInsensitiveContains("LeoRover pipeline") == true)
        #expect(snapshot.previousQuestionIncluded == false)
        #expect(snapshot.promptContainsPreviousQuestion == false)
        #expect(snapshot.contextBleedRisk == .low)
        #expect(snapshot.prompt.localizedCaseInsensitiveContains("Which part of the LeoRover pipeline was most fragile") == false)
        #expect(snapshot.prompt.localizedCaseInsensitiveContains(question.questionText))
    }

    @Test
    func diffusionAutoregressiveQuestionGetsModelComparisonGuidance() {
        let question = makeQuestion("Why did the diffusion model perform better than the autoregressive model?")

        let snapshot = PromptContextBuilder.promptSnapshot(
            question: question,
            context: mixedContext(),
            transcriptContext: "Interviewer: Could you walk me through LeoRover?",
            cvSummary: "Candidate has robotics experience.",
            jdSummary: "Robotics role.",
            stage: .fullAnswer
        )

        #expect(snapshot.questionIntent == .modelComparison)
        #expect(snapshot.prompt.localizedCaseInsensitiveContains("alternatives -> evaluation criteria -> evidence -> trade-off"))
        #expect(snapshot.prompt.localizedCaseInsensitiveContains(question.questionText))
        #expect(snapshot.ragChunkIDs.contains("diffusion"))
        #expect(snapshot.ragChunkIDs.contains("fragility") == false)
        #expect(snapshot.prompt.localizedCaseInsensitiveContains("pipeline was most fragile") == false)
    }

    @Test
    func whyRoleQuestionKeepsFullPrimaryQuestionAndRoleGuidance() {
        let question = makeQuestion("Why do you want to join our team?")

        let snapshot = PromptContextBuilder.generationRequestSnapshot(
            question: question,
            generationID: "generation-why-role",
            triggerPath: .autoDetect,
            source: .systemAudio,
            speaker: .interviewer,
            acceptedAt: Date(timeIntervalSince1970: 1_717_171_718),
            context: mixedContext(),
            transcriptContext: "Interviewer: Tell me about yourself.",
            cvSummary: "Candidate works on robotics perception and manipulation.",
            jdSummary: "Team builds deployed robotics systems.",
            stage: .firstAnswer
        )

        #expect(snapshot.questionText == "Why do you want to join our team?")
        #expect(snapshot.promptPrimaryQuestion == "Why do you want to join our team?")
        #expect(snapshot.questionIntent == .whyRole)
        #expect(snapshot.promptSnapshot.prompt.localizedCaseInsensitiveContains("target need -> supported candidate evidence -> motivation"))
        #expect(snapshot.promptSnapshot.ragChunkIDs.contains("jd-role"))
        #expect(snapshot.promptSnapshot.prompt.localizedCaseInsensitiveContains("Why do you want"))
    }

    @Test
    func candidateQuestionsIntentAsksInterviewerInsteadOfSelfIntroduction() {
        let question = makeQuestion("Do you have any questions for us?")

        let snapshot = PromptContextBuilder.promptSnapshot(
            question: question,
            context: mixedContext(),
            transcriptContext: "",
            cvSummary: "Candidate has MSc Robotics and a computer science background.",
            jdSummary: "Team evaluates robotics deployment success.",
            stage: .firstAnswer
        )

        #expect(snapshot.questionIntent == .candidateQuestions)
        #expect(snapshot.prompt.localizedCaseInsensitiveContains("concise questions about success, constraints, team, and evaluation"))
        #expect(snapshot.ragContextSnapshot.cvChunks.count == 3)
        #expect(snapshot.ragContextSnapshot.jobDescriptionChunks.map(\.id) == ["jd-role"])
        #expect(snapshot.prompt.localizedCaseInsensitiveContains("MSc Robotics") == true)
        #expect(snapshot.prompt.localizedCaseInsensitiveContains("generic self-introduction") == true)
    }

    @Test
    func promptRedactsRawAPIKeys() {
        let question = makeQuestion("Why do you want to join our team?")
        let rawKey = "sk-abcdefghijklmnopqrstuvwxyz1234567890"
        let context = RetrievedContext(
            cvChunks: [
                chunk("secret-cv", "DeepSeek API key: \(rawKey) should never appear in prompts.", .cv)
            ],
            jobDescriptionChunks: [
                chunk("secret-jd", "api key = \(rawKey) belongs in settings, not prompt context.", .jobDescription)
            ],
            additionalNotesChunks: []
        )

        let snapshot = PromptContextBuilder.promptSnapshot(
            question: question,
            context: context,
            transcriptContext: "Interviewer: background contained \(rawKey)",
            cvSummary: "Candidate summary mentions \(rawKey)",
            jdSummary: "Role summary mentions \(rawKey)",
            stage: .firstAnswer
        )

        #expect(snapshot.prompt.contains(rawKey) == false)
        #expect(snapshot.prompt.localizedCaseInsensitiveContains("[REDACTED_API_KEY]"))
    }

    private func makeQuestion(_ text: String) -> DetectedQuestion {
        DetectedQuestion(
            id: "prompt-builder-\(UUID().uuidString)",
            sessionID: "prompt-builder-session",
            transcriptSegmentID: "prompt-builder-segment",
            questionText: text,
            intent: .unclear,
            answerStrategy: .directAnswer,
            confidence: 0.95,
            reason: "Prompt builder test",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "test",
            promptVersion: "test",
            createdAt: Date()
        )
    }

    private func mixedContext() -> RetrievedContext {
        RetrievedContext(
            cvChunks: [
                chunk("self", "Education: MSc Robotics at the University of Manchester with a computer science background and robotics interest.", .cv),
                chunk("leorover", "LeoRover autonomous object retrieval robot using ROS2, YOLOv8, target localisation, navigation, and manipulation.", .cv),
                chunk("fragility", "The pipeline was most fragile when moving from a clean demo to real robot execution because noisy perception and timing mismatch caused failures.", .cv),
                chunk("diffusion", "VLA MuJoCo evaluation compared diffusion, autoregressive, and flow-matching decoders; diffusion produced smoother continuous actions and seven out of ten successful grasps.", .cv),
                chunk("skills", "Skills: Python, ROS2, C++, robotics projects, control coordination, experiment scripting, and performance-critical robotics systems.", .cv)
            ],
            jobDescriptionChunks: [
                chunk("jd-role", "Robotics software team focused on perception, real-world deployment, evaluation, reliability, and success criteria.", .jobDescription)
            ],
            additionalNotesChunks: [
                chunk("note", "Ask thoughtful questions about team success criteria and deployed robotics reliability.", .additionalNotes)
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
