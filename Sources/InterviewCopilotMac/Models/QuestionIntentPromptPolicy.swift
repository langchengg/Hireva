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

    /// Returns a complete local fallback answer for the active question.
    ///
    /// These answers may become the first visible response when DeepSeek is late
    /// or Stage B times out, so they must be speakable answers rather than
    /// instructions. Model-comparison fallbacks must directly compare diffusion
    /// and autoregressive behavior.
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
                sayFirst: "My interpretation is that a diffusion-based policy can be more stable because it denoises a whole continuous action sequence or trajectory, which tends to produce smoother and more robust manipulation motions. An autoregressive policy predicts actions step by step, so small mistakes can compound and accumulate over the sequence.",
                keyPoints: ["Diffusion refines a full continuous action trajectory through denoising.", "Autoregressive and flow-matching variants were less robust, and autoregressive prediction can accumulate compounding errors step by step.", "In MuJoCo, diffusion reached seven out of ten successful grasps, helped by smoother action generation."]
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

    private static func normalize(_ text: String) -> String {
        " " + text
            .lowercased()
            .replacingOccurrences(of: "c++", with: "c plus plus")
            .replacingOccurrences(of: "ros 2", with: "ros2")
            .replacingOccurrences(of: "leader rover", with: "leorover")
            .replacingOccurrences(of: "leah rover", with: "leorover")
            .replacingOccurrences(of: "leo rover", with: "leorover")
            .replacingOccurrences(of: "lero", with: "leorover")
            .replacingOccurrences(of: "auto rig progressive", with: "autoregressive")
            .replacingOccurrences(of: "auto regressive", with: "autoregressive")
            .replacingOccurrences(of: "diffusion-based policy", with: "diffusion policy")
            .replacingOccurrences(of: "diffusion based policy", with: "diffusion policy")
            .replacingOccurrences(of: "from n to end", with: "from end to end")
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ") + " "
    }
}
