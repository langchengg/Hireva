// Maps interviewer question text to answer intent, filtered context, and local
// fallback wording.
// This file should stay deterministic and side-effect free; it must not call
// providers, read AppState, or mutate RAG scoring.

import Foundation

/// Deterministic policy for question intent, context filtering, and fallback
/// answer selection.
///
/// Intent-specific retrieval should prioritize relevant project chunks, but it
/// must not reinterpret or replace the current question text.
enum QuestionIntentPromptPolicy {
    static func normalizedQuestionText(for text: String) -> String {
        normalize(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func intent(for questionText: String) -> AnswerRelevanceIntent {
        IntentRouter.answerIntent(for: questionText)
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
        case .decoderComparison:
            return RetrievedContext(
                cvChunks: pick(context.cvChunks, keywords: ["vla", "mujoco", "franka", "decoder", "autoregressive", "diffusion", "flow-matching", "flow matching", "seven out of ten", "7/10", "one out of ten", "1/10"], limit: 3),
                jobDescriptionChunks: [],
                additionalNotesChunks: Array(context.additionalNotesChunks.prefix(1))
            )
        case .perceptionDebugging:
            return RetrievedContext(
                cvChunks: pick(context.cvChunks, keywords: ["yolov8", "detector", "wrong prediction", "false positive", "frames", "calibration", "lighting", "occlusion", "bounding boxes", "confidence", "temporal", "spatial", "recovery", "leorover"], limit: 3),
                jobDescriptionChunks: [],
                additionalNotesChunks: Array(context.additionalNotesChunks.prefix(1))
            )
        case .technicalTradeoff:
            return RetrievedContext(
                cvChunks: pick(context.cvChunks, keywords: ["trade-off", "tradeoff", "robustness", "latency", "complexity", "reliability", "leorover", "vla", "filtering", "recovery", "ros2", "integration"], limit: 3),
                jobDescriptionChunks: Array(context.jobDescriptionChunks.prefix(1)),
                additionalNotesChunks: Array(context.additionalNotesChunks.prefix(1))
            )
        case .datasetAdaptation:
            return RetrievedContext(
                cvChunks: pick(context.cvChunks, keywords: ["droid", "mujoco", "franka", "trajectory", "trajectories", "demonstration", "action", "observation", "coordinate", "timing"], limit: 3),
                jobDescriptionChunks: [],
                additionalNotesChunks: Array(context.additionalNotesChunks.prefix(1))
            )
        case .simToRealDebugging:
            return RetrievedContext(
                cvChunks: pick(context.cvChunks, keywords: ["sim-to-real", "sim to real", "mujoco", "real robot", "calibration", "contact dynamics", "action scaling", "latency", "domain randomization", "failure"], limit: 3),
                jobDescriptionChunks: [],
                additionalNotesChunks: Array(context.additionalNotesChunks.prefix(1))
            )
        case .projectComparison:
            return RetrievedContext(
                cvChunks: pick(context.cvChunks, keywords: ["vla", "mujoco", "franka", "action decoder", "leorover", "ros2", "yolov8", "navigation", "manipulation", "real robot"], limit: 4),
                jobDescriptionChunks: Array(context.jobDescriptionChunks.prefix(1)),
                additionalNotesChunks: Array(context.additionalNotesChunks.prefix(1))
            )
        case .systemIntegrationDebugging:
            return RetrievedContext(
                cvChunks: pick(context.cvChunks, keywords: ["leorover", "ros2", "system integration", "perception", "navigation", "manipulation", "timing", "logs", "timestamps", "sensor", "recovery", "reliability"], limit: 3),
                jobDescriptionChunks: Array(context.jobDescriptionChunks.prefix(1)),
                additionalNotesChunks: Array(context.additionalNotesChunks.prefix(1))
            )
        case .improvementPlan:
            return RetrievedContext(
                cvChunks: pick(context.cvChunks, keywords: ["leorover", "real robot", "evaluation", "failure cases", "more objects", "initial positions", "robust perception", "lighting", "occlusion", "spatial consistency", "calibration", "latency", "recovery"], limit: 3),
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
        case .candidateQuestions, .interviewerQuestions:
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

    /// Returns a complete local fallback answer for the active question.
    ///
    /// These answers may become the first visible response when DeepSeek is late
    /// or Stage B times out, so they must be speakable answers rather than
    /// instructions. Model-comparison fallbacks must directly compare diffusion
    /// and autoregressive behavior.
    static func fallbackAnswer(for question: DetectedQuestion) -> IntentFallbackAnswer {
        ProjectGroundedFallbackPolicy.fallbackAnswer(for: question)
    }

    static func answerShape(for intent: AnswerRelevanceIntent) -> String {
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
        case .decoderComparison:
            return "MuJoCo VLA setup -> autoregressive vs diffusion vs flow-matching -> empirical result -> lesson about trajectory generation"
        case .perceptionDebugging:
            return "reproduce frames/logs -> inspect boxes/classes/confidence -> check calibration/lighting/occlusion -> validate/recover before retraining"
        case .technicalTradeoff:
            return "trade-off -> concrete robotics decision -> reliability impact -> lesson learned"
        case .datasetAdaptation:
            return "DROID source data -> MuJoCo/Franka target setup -> action/observation mapping -> coordinate/timing validation"
        case .simToRealDebugging:
            return "compare sim versus real -> observations/actions/timing/calibration -> isolate perception/control/dynamics/distribution shift"
        case .projectComparison:
            return "VLA learning-policy simulation work -> LeoRover real robot integration work -> concrete difference and shared robotics lesson"
        case .systemIntegrationDebugging:
            return "STAR debugging story -> LeoRover/ROS2 integration issue -> logs/timestamps/isolation -> recovery/reliability lesson"
        case .improvementPlan:
            return "what to improve first -> why -> concrete next steps"
        case .whyRole:
            return "role/team alignment -> robotics/AI/perception relevance -> real-world deployment interest -> growth motivation"
        case .skillComfort:
            return "Python -> ROS2 -> C++ -> honest strength and active learning"
        case .candidateQuestions:
            return "ask the interviewer one question about team, evaluation, deployment, or success criteria; do not answer about my background"
        case .interviewerQuestions:
            return "ask the interviewer 3-5 concise questions about success criteria, deployment challenges, team structure, infrastructure, or ownership; do not answer about my background"
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

    private static func normalize(_ text: String) -> String {
        " " + ASRCanonicalizer.canonicalizeTerms(text)
            .lowercased()
            .replacingOccurrences(of: "c++", with: "c plus plus")
            .replacingOccurrences(of: "ros 2", with: "ros2")
            .replacingOccurrences(of: "flow matching", with: "flow-matching")
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ") + " "
    }

    private static func isDecoderComparisonQuestion(_ text: String) -> Bool {
        let mentionsDecoderComparison = text.contains("comparing") ||
            text.contains("compared") ||
            text.contains("what did you learn")
        let mentionsVLAContext = text.contains("mujoco") ||
            text.contains("vla") ||
            text.contains("franka") ||
            text.contains("flow-matching")
        let modelTerms = ["autoregressive", "diffusion", "flow-matching"].filter { text.contains($0) }.count
        return mentionsDecoderComparison && mentionsVLAContext && modelTerms >= 2
    }

    private static func isPerceptionDebuggingQuestion(_ text: String) -> Bool {
        let mentionsDetector = text.contains("yolov8") ||
            text.contains("detector") ||
            text.contains("detection") ||
            text.contains("prediction")
        let mentionsDebugging = text.contains("debug") ||
            text.contains("wrong prediction") ||
            text.contains("confident but wrong") ||
            text.contains("false positive")
        return mentionsDetector && mentionsDebugging
    }
}
