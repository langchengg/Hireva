import Foundation

enum AnswerRelevanceIntent: String, CaseIterable, Codable, Hashable, Identifiable {
    case tellMeAboutYourself = "tell_me_about_yourself"
    case projectWalkthrough = "project_walkthrough"
    case technicalChallenge = "technical_challenge"
    case errorHandling = "error_handling"
    case modelComparison = "model_comparison"
    case improvementPlan = "improvement_plan"
    case whyRole = "why_role"
    case skillComfort = "skill_comfort"
    case candidateQuestions = "candidate_questions"
    case diffusionPolicy = "diffusion_policy"
    case generic

    var id: String { rawValue }
}

enum AnswerPromptStage: String, Codable, Hashable {
    case firstAnswer
    case fullAnswer
    case sectionStream
    case jsonCard
}

enum ContextBleedRisk: String, Codable, Hashable {
    case low
    case medium
    case high
}

struct AnswerPromptSnapshot: Equatable {
    var detectedQuestionID: String?
    var questionTextSnapshot: String
    var normalizedQuestionText: String
    var questionIntent: AnswerRelevanceIntent
    var transcriptSegmentID: String?
    var ragContextSnapshot: RetrievedContext
    var ragChunkPreviews: [String]
    var ragChunkIDs: [String]
    var ragChunkIntents: [AnswerRelevanceIntent]
    var prompt: String
    var promptPrimaryQuestion: String
    var promptContainsPreviousQuestion: Bool
    var previousQuestionIncluded: Bool
    var previousQuestionText: String?
    var contextBleedRisk: ContextBleedRisk
    var promptTokenEstimate: Int
}

struct GenerationRequestSnapshot: Equatable {
    var detectedQuestionID: String
    var generationID: String
    var transcriptSegmentID: String?
    var questionText: String
    var normalizedQuestionText: String
    var questionIntent: AnswerRelevanceIntent
    var source: AudioSourceType?
    var speaker: SpeakerRole?
    var triggerPath: GenerationTriggerPath
    var acceptedAt: Date
    var ragContextSnapshot: RetrievedContext
    var promptSnapshot: AnswerPromptSnapshot

    var promptPrimaryQuestion: String { promptSnapshot.promptPrimaryQuestion }
    var promptContainsPreviousQuestion: Bool { promptSnapshot.promptContainsPreviousQuestion }
    var previousQuestionIncluded: Bool { promptSnapshot.previousQuestionIncluded }
    var previousQuestionText: String? { promptSnapshot.previousQuestionText }
    var contextBleedRisk: ContextBleedRisk { promptSnapshot.contextBleedRisk }
    var ragChunkIDs: [String] { promptSnapshot.ragChunkIDs }
    var ragChunkIntents: [AnswerRelevanceIntent] { promptSnapshot.ragChunkIntents }
}

struct IntentFallbackAnswer: Equatable {
    var sayFirst: String
    var keyPoints: [String]
}

enum AnswerRelevancePolicy {
    static func normalizedQuestionText(for text: String) -> String {
        normalize(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func intent(for questionText: String) -> AnswerRelevanceIntent {
        let text = normalize(questionText)
        if text.contains("diffusion") && (text.contains("autoregressive") || text.contains("auto regressive")) {
            return .modelComparison
        }
        if text.contains("diffusion") && text.contains("robotic manipulation") {
            return .diffusionPolicy
        }
        if text.contains("action decoder") || text.contains("policy") || text.contains("flow matching") || text.contains("flow-matching") {
            return .modelComparison
        }
        if text.contains("diffusion decoder") ||
            text.contains("diffusion-based policy") ||
            text.contains("diffusion policy") ||
            text.contains("mujoco") ||
            text.contains("mu jo co") ||
            text.contains("autoregressive") ||
            text.contains("flow matching") {
            return .modelComparison
        }
        if text.contains("hardest technical challenge") ||
            text.contains("hardest challenge") ||
            text.contains("pipeline was most fragile") ||
            text.contains("most fragile") ||
            text.contains("clean demo") ||
            text.contains("real robot execution") {
            return .technicalChallenge
        }
        if text.contains("about yourself") || text.contains("brought you into robotics") || text.contains("introduce yourself") {
            return .tellMeAboutYourself
        }
        if text.contains("leorover") || text.contains("leo rover") || text.contains("walk me through") {
            return .projectWalkthrough
        }
        if text.contains("noisy detections") || text.contains("localisation errors") || text.contains("localization errors") {
            return .errorHandling
        }
        if text.contains("another month") || text.contains("change first") || text.contains("improve first") {
            return .improvementPlan
        }
        if text.contains("python") || text.contains("c plus plus") || text.contains("ros2") || text.contains("rose two") {
            return .skillComfort
        }
        if text.contains("questions for us") || text.contains("questions for you") || text.contains("do you have any questions") {
            return .candidateQuestions
        }
        if text.contains("why do you want") || text.contains("join our team") || text.contains("this role") {
            return .whyRole
        }
        return .generic
    }

    static func promptSnapshot(
        question: DetectedQuestion,
        context: RetrievedContext,
        transcriptContext: String,
        cvSummary: String,
        jdSummary: String,
        stage: AnswerPromptStage
    ) -> AnswerPromptSnapshot {
        let questionTextSnapshot = question.questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let intent = intent(for: questionTextSnapshot)
        let filteredContext = filterContext(context, intent: intent)
        let background = backgroundTranscript(
            from: transcriptContext,
            currentQuestion: questionTextSnapshot,
            currentIntent: intent
        )
        let prompt = buildPrompt(
            questionTextSnapshot: questionTextSnapshot,
            intent: intent,
            filteredContext: filteredContext,
            backgroundText: background.text,
            cvSummary: cvSummary,
            jdSummary: jdSummary,
            stage: stage
        )
        let chunkIntents = chunkIntents(from: filteredContext)
        return AnswerPromptSnapshot(
            detectedQuestionID: question.id,
            questionTextSnapshot: questionTextSnapshot,
            normalizedQuestionText: normalizedQuestionText(for: questionTextSnapshot),
            questionIntent: intent,
            transcriptSegmentID: question.transcriptSegmentID,
            ragContextSnapshot: filteredContext,
            ragChunkPreviews: chunkPreviews(from: filteredContext),
            ragChunkIDs: chunkIDs(from: filteredContext),
            ragChunkIntents: chunkIntents,
            prompt: prompt,
            promptPrimaryQuestion: questionTextSnapshot,
            promptContainsPreviousQuestion: background.promptContainsPreviousQuestion,
            previousQuestionIncluded: background.included,
            previousQuestionText: background.previousQuestionText,
            contextBleedRisk: background.risk,
            promptTokenEstimate: estimateTokens(prompt)
        )
    }

    static func generationRequestSnapshot(
        question: DetectedQuestion,
        generationID: String,
        triggerPath: GenerationTriggerPath,
        source: AudioSourceType?,
        speaker: SpeakerRole?,
        acceptedAt: Date,
        context: RetrievedContext,
        transcriptContext: String,
        cvSummary: String,
        jdSummary: String,
        stage: AnswerPromptStage
    ) -> GenerationRequestSnapshot {
        let prompt = promptSnapshot(
            question: question,
            context: context,
            transcriptContext: transcriptContext,
            cvSummary: cvSummary,
            jdSummary: jdSummary,
            stage: stage
        )
        return GenerationRequestSnapshot(
            detectedQuestionID: question.id,
            generationID: generationID,
            transcriptSegmentID: question.transcriptSegmentID,
            questionText: prompt.questionTextSnapshot,
            normalizedQuestionText: prompt.normalizedQuestionText,
            questionIntent: prompt.questionIntent,
            source: source,
            speaker: speaker,
            triggerPath: triggerPath,
            acceptedAt: acceptedAt,
            ragContextSnapshot: prompt.ragContextSnapshot,
            promptSnapshot: prompt
        )
    }

    static func filterContext(_ context: RetrievedContext, intent: AnswerRelevanceIntent) -> RetrievedContext {
        switch intent {
        case .tellMeAboutYourself:
            return RetrievedContext(
                cvChunks: pick(context.cvChunks, keywords: ["education", "msc", "robotics", "university", "computer science", "perception", "manipulation"], limit: 2),
                jobDescriptionChunks: pick(context.jobDescriptionChunks, keywords: ["robotics", "role", "team"], limit: 1),
                additionalNotesChunks: Array(context.additionalNotesChunks.prefix(1))
            )
        case .projectWalkthrough:
            return RetrievedContext(
                cvChunks: pick(context.cvChunks, keywords: ["leorover", "leo rover", "ros2", "yolov8", "navigation", "manipulation", "object retrieval", "localisation", "localization"], limit: 3),
                jobDescriptionChunks: Array(context.jobDescriptionChunks.prefix(1)),
                additionalNotesChunks: Array(context.additionalNotesChunks.prefix(1))
            )
        case .technicalChallenge:
            return RetrievedContext(
                cvChunks: pick(context.cvChunks, keywords: ["challenge", "fragile", "clean demo", "noisy", "localisation", "localization", "timing", "integration", "real robot", "real robot execution", "unpredictable"], limit: 3),
                jobDescriptionChunks: Array(context.jobDescriptionChunks.prefix(1)),
                additionalNotesChunks: Array(context.additionalNotesChunks.prefix(1))
            )
        case .errorHandling:
            return RetrievedContext(
                cvChunks: pick(context.cvChunks, keywords: ["noisy", "filtering", "repeated observations", "stability", "recovery", "retry", "reposition", "localisation", "localization"], limit: 3),
                jobDescriptionChunks: [],
                additionalNotesChunks: Array(context.additionalNotesChunks.prefix(1))
            )
        case .modelComparison, .diffusionPolicy:
            return RetrievedContext(
                cvChunks: pick(context.cvChunks, keywords: ["diffusion", "autoregressive", "flow-matching", "flow matching", "mujoco", "continuous action", "seven out of ten", "7 out of 10"], limit: 3),
                jobDescriptionChunks: [],
                additionalNotesChunks: Array(context.additionalNotesChunks.prefix(1))
            )
        case .improvementPlan:
            return RetrievedContext(
                cvChunks: pick(context.cvChunks, keywords: ["evaluation", "failure cases", "more objects", "initial positions", "robust perception", "visual grounding", "reranking", "grasp candidates"], limit: 3),
                jobDescriptionChunks: Array(context.jobDescriptionChunks.prefix(1)),
                additionalNotesChunks: Array(context.additionalNotesChunks.prefix(1))
            )
        case .whyRole:
            return RetrievedContext(
                cvChunks: pick(context.cvChunks, keywords: ["robotics", "ai", "perception", "manipulation", "deployment", "engineering", "systems"], limit: 1),
                jobDescriptionChunks: pick(context.jobDescriptionChunks, keywords: ["role", "team", "robotics", "deployment", "perception", "ai"], limit: 2),
                additionalNotesChunks: Array(context.additionalNotesChunks.prefix(1))
            )
        case .skillComfort:
            return RetrievedContext(
                cvChunks: pick(context.cvChunks, keywords: ["python", "c++", "c plus plus", "ros2", "rose two", "skills", "tools", "robotics projects", "performance"], limit: 3),
                jobDescriptionChunks: pick(context.jobDescriptionChunks, keywords: ["python", "c++", "ros2", "software"], limit: 1),
                additionalNotesChunks: Array(context.additionalNotesChunks.prefix(1))
            )
        case .candidateQuestions:
            return RetrievedContext(
                cvChunks: [],
                jobDescriptionChunks: pick(context.jobDescriptionChunks, keywords: ["team", "evaluation", "deployment", "success", "robotics", "role"], limit: 2),
                additionalNotesChunks: Array(context.additionalNotesChunks.prefix(1))
            )
        case .generic:
            return RetrievedContext(
                cvChunks: Array(context.cvChunks.prefix(2)),
                jobDescriptionChunks: Array(context.jobDescriptionChunks.prefix(1)),
                additionalNotesChunks: Array(context.additionalNotesChunks.prefix(1))
            )
        }
    }

    static func fallbackAnswer(for question: DetectedQuestion) -> IntentFallbackAnswer {
        switch intent(for: question.questionText) {
        case .tellMeAboutYourself:
            return IntentFallbackAnswer(
                sayFirst: "I’m currently studying MSc Robotics at the University of Manchester, and my computer science background brought me into robotics because it combines software, perception, manipulation, and real-world AI systems.",
                keyPoints: ["MSc Robotics and computer science background.", "Interest in robotics through software, perception, control, and AI.", "Recent direction: perception, manipulation, and decision making."]
            )
        case .projectWalkthrough:
            return IntentFallbackAnswer(
                sayFirst: "My LeoRover project was an autonomous object retrieval robot. I worked on the ROS2 pipeline, YOLOv8 object detection, target localisation, navigation coordination, and connecting that perception output to manipulation.",
                keyPoints: ["Goal: search, localise, navigate, and pick up a target object.", "Role: ROS2, YOLOv8, localisation, navigation, and manipulation coordination.", "Learning: real robot integration matters as much as each module."]
            )
        case .technicalChallenge:
            return IntentFallbackAnswer(
                sayFirst: "The hardest technical challenge was making the real robot pipeline reliable, because noisy perception, localisation instability, timing mismatch, and module integration made real robot execution much less predictable than simulation.",
                keyPoints: ["Challenge: perception, localisation, navigation, and manipulation integration.", "Why hard: noisy inputs and real robot uncertainty.", "Outcome: added more robust coordination and recovery behaviour."]
            )
        case .errorHandling:
            return IntentFallbackAnswer(
                sayFirst: "I handled noisy detections by using filtering, repeated observations, and a stability threshold before acting, then adding recovery behaviour such as retrying, repositioning, or adjusting when localisation was unreliable.",
                keyPoints: ["Did not trust a single detection.", "Used repeated observations and stability checks.", "Added retry, reposition, and recovery behaviour."]
            )
        case .modelComparison, .diffusionPolicy:
            return IntentFallbackAnswer(
                sayFirst: "The diffusion decoder performed better because it produced smoother continuous actions and was more robust to small trajectory errors than the autoregressive and flow-matching decoders; in my MuJoCo evaluation it achieved seven out of ten successful grasps.",
                keyPoints: ["Diffusion handled continuous action distributions better.", "Autoregressive and flow-matching were less robust in the evaluation.", "Result: diffusion reached seven out of ten successful grasping episodes."]
            )
        case .improvementPlan:
            return IntentFallbackAnswer(
                sayFirst: "If I had another month, I would improve the evaluation pipeline first by testing more objects, more initial positions, and more failure cases, then strengthen robust perception, visual grounding, and grasp candidate reranking.",
                keyPoints: ["First priority: broader evaluation and failure cases.", "Next: more robust perception and visual grounding.", "Then: better reranking for grasp candidates."]
            )
        case .whyRole:
            return IntentFallbackAnswer(
                sayFirst: "I’m interested in this role because it connects directly with my robotics, AI, and perception experience, and I want to keep building systems that move from prototypes into reliable real robot deployment while growing as an engineer.",
                keyPoints: ["Role alignment with robotics, AI, and perception.", "Interest in real robot deployment and deployed systems.", "Growth motivation in practical robotics engineering."]
            )
        case .skillComfort:
            return IntentFallbackAnswer(
                sayFirst: "I’m comfortable with Python and ROS2 from my robotics projects, especially perception pipelines, robot coordination, and experiment scripting. I have used C++ less than Python, but I understand its importance for performance-critical robotics systems and I’m actively improving it.",
                keyPoints: ["Python: strong for experiments, perception, and scripting.", "ROS2: used in robotics project pipelines and coordination.", "C++: honest learning area, important for performance-critical systems."]
            )
        case .candidateQuestions:
            return IntentFallbackAnswer(
                sayFirst: "Yes, I’d like to ask how your team evaluates success when moving a robotics system from prototype demos to reliable real-world deployment.",
                keyPoints: ["Ask about team evaluation and success criteria.", "Focus on deployment, reliability, and real-world robotics.", "Keep it interviewer-facing, not a self-introduction."]
            )
        case .generic:
            return IntentFallbackAnswer(
                sayFirst: "I’d answer this directly, connect it to a concrete robotics example, and keep the focus on what I did, why it mattered, and what I learned.",
                keyPoints: ["Direct answer first.", "Concrete example from experience.", "Outcome or lesson learned."]
            )
        }
    }

    static func estimateTokens(_ text: String) -> Int {
        max(1, Int(Double(text.split(whereSeparator: \.isWhitespace).count) * 1.35))
    }

    private static func buildPrompt(
        questionTextSnapshot: String,
        intent: AnswerRelevanceIntent,
        filteredContext: RetrievedContext,
        backgroundText: String,
        cvSummary: String,
        jdSummary: String,
        stage: AnswerPromptStage
    ) -> String {
        let outputInstructions: String
        switch stage {
        case .firstAnswer:
            outputInstructions = "Output only one natural first-person spoken answer, 1 to 3 concise sentences."
        case .sectionStream:
            outputInstructions = """
            Return plain text sections only:
            STRATEGY:
            SAY_FIRST:
            KEY_POINTS:
            FOLLOW_UP_READY:
            CAUTION:
            """
        case .fullAnswer, .jsonCard:
            outputInstructions = """
            Return valid JSON only using keys: strategy, say_first, key_points, follow_up_ready, confidence, caution, evidence_used, risk_level.
            """
        }

        return """
        CURRENT QUESTION TO ANSWER:
        "\(questionTextSnapshot)"

        You must answer this exact question directly.
        Previous transcript is background only and must not change the question.

        Your task:
        Answer this exact question directly in first person.
        Do not answer a previous question.
        Do not give a generic self-introduction unless the question asks for it.
        Do not summarize the CV unless relevant to the question.

        QUESTION INTENT:
        \(intent.rawValue)

        ANSWER SHAPE:
        \(answerShape(for: intent))

        OUTPUT FORMAT:
        \(outputInstructions)

        RELEVANT CONTEXT:
        Candidate summary:
        \(cvSummary)

        Target role summary:
        \(jdSummary)

        Selected local evidence:
        \(filteredContext.promptText.isEmpty ? "No matching local chunks were found. Use the question intent and profile summary; do not fabricate unsupported specifics." : filteredContext.promptText)

        BACKGROUND FROM EARLIER INTERVIEW:
        \(backgroundText)
        """
    }

    private static func answerShape(for intent: AnswerRelevanceIntent) -> String {
        switch intent {
        case .tellMeAboutYourself:
            return "education/background -> robotics interest -> relevant project direction -> concise role fit"
        case .projectWalkthrough:
            return "project goal -> my role -> technical pipeline -> result or learning"
        case .technicalChallenge:
            return "challenge -> why it was hard -> action taken -> outcome"
        case .errorHandling:
            return "noisy detections/localisation issue -> filtering/repeated observations/recovery -> robust execution"
        case .modelComparison, .diffusionPolicy:
            return "directly compare diffusion vs autoregressive vs flow-matching -> smoother continuous actions -> robustness -> success rate if available"
        case .improvementPlan:
            return "what to improve first -> why -> concrete next steps"
        case .whyRole:
            return "role/team alignment -> robotics/AI/perception relevance -> real-world deployment interest -> growth motivation"
        case .skillComfort:
            return "Python -> ROS2 -> C++ -> honest strength and active learning"
        case .candidateQuestions:
            return "ask the interviewer one question about team, evaluation, deployment, or success criteria; do not answer about my background"
        case .generic:
            return "direct answer -> concrete example -> result or lesson"
        }
    }

    private static func pick(_ chunks: [DocumentChunk], keywords: [String], limit: Int) -> [DocumentChunk] {
        let matches = chunks.filter { chunk in
            let content = normalize((chunk.sectionTitle ?? "") + " " + chunk.content)
            return keywords.contains { content.contains(normalize($0).trimmingCharacters(in: .whitespaces)) }
        }
        return Array((matches.isEmpty ? chunks : matches).prefix(limit))
    }

    private static func chunkPreviews(from context: RetrievedContext) -> [String] {
        (context.cvChunks + context.jobDescriptionChunks + context.additionalNotesChunks).map { chunk in
            let title = chunk.sectionTitle ?? chunk.documentType.shortTitle
            let preview = chunk.content.replacingOccurrences(of: "\n", with: " ").prefix(120)
            return "\(title): \(preview)"
        }
    }

    private static func chunkIDs(from context: RetrievedContext) -> [String] {
        (context.cvChunks + context.jobDescriptionChunks + context.additionalNotesChunks).map(\.id)
    }

    private static func chunkIntents(from context: RetrievedContext) -> [AnswerRelevanceIntent] {
        (context.cvChunks + context.jobDescriptionChunks + context.additionalNotesChunks).map { chunk in
            intent(for: [chunk.sectionTitle ?? "", chunk.content].joined(separator: " "))
        }
    }

    private static func backgroundTranscript(
        from transcriptContext: String,
        currentQuestion: String,
        currentIntent: AnswerRelevanceIntent
    ) -> (text: String, included: Bool, previousQuestionText: String?, promptContainsPreviousQuestion: Bool, risk: ContextBleedRisk) {
        let trimmed = transcriptContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("No earlier background included.", false, nil, false, .low)
        }

        let bounded = ContextBudgeter.limitWords(trimmed, maxWords: 130)
        let previousQuestion = extractQuestionLikeText(from: bounded)
        let previousIntent = previousQuestion.map(intent(for:))
        let currentNormalized = normalizedQuestionText(for: currentQuestion)
        let previousNormalized = previousQuestion.map(normalizedQuestionText(for:)) ?? ""
        let isDifferentQuestion = !previousNormalized.isEmpty && previousNormalized != currentNormalized
        let intentDiffers = previousIntent != nil && previousIntent != currentIntent

        if isDifferentQuestion && intentDiffers {
            return (
                "Earlier transcript contained a different question and was excluded to keep this answer focused.",
                false,
                previousQuestion,
                false,
                .low
            )
        }

        let cleaned = stripCurrentQuestion(currentQuestion, from: bounded)
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ("No earlier background included.", false, previousQuestion, false, .low)
        }

        let containsPrevious = previousQuestion.map { normalize(cleaned).contains(normalize($0).trimmingCharacters(in: .whitespacesAndNewlines)) } ?? false
        let risk: ContextBleedRisk = containsPrevious && isDifferentQuestion ? .medium : .low
        return (cleaned, true, previousQuestion, containsPrevious, risk)
    }

    private static func extractQuestionLikeText(from text: String) -> String? {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let candidates = lines.isEmpty ? [text] : lines
        for candidate in candidates.reversed() {
            let cleaned = candidate
                .replacingOccurrences(of: "Interviewer:", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = normalize(cleaned)
            if cleaned.contains("?") ||
                normalized.contains(" could you ") ||
                normalized.contains(" what ") ||
                normalized.contains(" why ") ||
                normalized.contains(" how ") ||
                normalized.contains(" which ") ||
                normalized.contains(" do you ") {
                return cleaned
            }
        }
        return nil
    }

    private static func stripCurrentQuestion(_ question: String, from text: String) -> String {
        let current = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return text }
        return text
            .replacingOccurrences(of: current, with: "", options: [.caseInsensitive])
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func normalize(_ text: String) -> String {
        " " + text
            .lowercased()
            .replacingOccurrences(of: "c++", with: "c plus plus")
            .replacingOccurrences(of: "ros 2", with: "ros2")
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ") + " "
    }
}
